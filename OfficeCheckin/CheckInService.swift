import Combine
import CoreLocation
import CoreWLAN
import Foundation
import ServiceManagement
import SwiftData

@MainActor
final class CheckInService: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum AutomaticStatus { case success, waiting, warning }
    @Published private(set) var currentWiFi = "Checking…"
    @Published private(set) var wifiHint: String?
    @Published private(set) var isCheckedInToday = false
    @Published private(set) var automaticStatus: AutomaticStatus = .waiting
    @Published private(set) var statusText = "Waiting for automatic check-in"
    @Published var lastError: String?

    private var timer: Timer?
    private var context: ModelContext?
    private let locationManager = CLLocationManager()
    static let targetKey = "targetSSID"
    static let defaultSSID = "verizion_QV96NR"

    var targetSSID: String {
        UserDefaults.standard.string(forKey: Self.targetKey) ?? Self.defaultSSID
    }
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    override init() {
        super.init()
        locationManager.delegate = self
        if CLLocationManager.locationServicesEnabled(), locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func start(using modelContext: ModelContext) {
        guard timer == nil else { return }
        context = modelContext
        enableLaunchAtLogin()
        beginPolling()
    }

    func refresh() {
        let existing = todayCheckIn()
        isCheckedInToday = existing != nil
        // A manual/backfill result is provisional: a later automatic success replaces it.
        if existing?.source == "wifi" {
            automaticStatus = .success
            statusText = "Checked in today"
            scheduleNextDay()
            return
        }
        let ssid = wifiName()
        currentWiFi = ssid ?? "Not connected"
        wifiHint = ssid == nil ? "Allow Location access and keep App Sandbox disabled to read the Wi-Fi name." : nil
        guard let ssid else { automaticStatus = .waiting; statusText = "Waiting for \(targetSSID)"; return }
        guard ssidMatches(ssid, targetSSID) else {
            automaticStatus = .waiting
            statusText = "Connected to \(ssid), but target is \(targetSSID)"
            wifiHint = "The Wi-Fi name must match the Target WiFi setting. Update it if the detected name is correct."
            return
        }
        checkIn(ssid: ssid, source: "wifi")
    }

    func manualCheckIn() {
        checkIn(ssid: wifiName() ?? "Manual check-in", source: "manual")
    }

    func backfill(date: Date) {
        guard date <= .now else { lastError = "A future date cannot be checked in."; return }
        guard let context else { lastError = "The local database is unavailable."; return }
        let key = dayKey(for: date), predicate = #Predicate<CheckIn> { $0.dayKey == key }
        guard (try? context.fetch(FetchDescriptor(predicate: predicate)).isEmpty) != false else { lastError = "This date already has a check-in."; return }
        let timestamp = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        context.insert(CheckIn(dayKey: key, checkedInAt: timestamp, ssid: "Manual backfill", source: "backfill"))
        context.insert(OperationLog(action: "Added backfill", dayKey: key))
        do { try context.save(); _ = try ExportService.export(from: context); _ = try ExportService.exportOperations(from: context); lastError = nil }
        catch { lastError = "Backfill failed: \(error.localizedDescription)" }
    }

    func removeCheckIn(date: Date) {
        guard date <= .now else { lastError = "A future date cannot be removed."; return }
        guard let context else { lastError = "The local database is unavailable."; return }
        let key = dayKey(for: date), predicate = #Predicate<CheckIn> { $0.dayKey == key }
        guard let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first else { lastError = "There is no check-in for this date."; return }
        context.delete(existing)
        context.insert(OperationLog(action: "Removed check-in", dayKey: key))
        do { try context.save(); _ = try ExportService.export(from: context); _ = try ExportService.exportOperations(from: context); refresh(); lastError = nil }
        catch { lastError = "Removal failed: \(error.localizedDescription)" }
    }

    func saveTargetSSID(_ value: String) {
        let newTarget = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !ssidMatches(newTarget, targetSSID)
        UserDefaults.standard.set(newTarget, forKey: Self.targetKey)
        if changed { resetTodayForTargetChange(); beginPolling() }
        else { refresh() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = "Could not update the login-item setting: \(error.localizedDescription)" }
    }

    func report(_ error: Error) { lastError = error.localizedDescription }

    private func enableLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() }
        catch { lastError = "Launch at Login could not be enabled: \(error.localizedDescription)" }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    private func wifiName() -> String? {
        // Prefer the built-in network utility; it is more reliable for a developer-signed app.
        let ports = command("/usr/sbin/networksetup", ["-listallhardwareports"]).components(separatedBy: .newlines)
        for (index, line) in ports.enumerated() where line.contains("Hardware Port: Wi-Fi") {
            guard let deviceLine = ports.dropFirst(index + 1).first(where: { $0.hasPrefix("Device:") }) else { continue }
            let device = deviceLine.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            let answer = command("/usr/sbin/networksetup", ["-getairportnetwork", device])
            let prefix = "Current Wi-Fi Network: "
            if answer.hasPrefix(prefix) { return String(answer.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // CoreWLAN remains a useful fallback after location access is approved.
        if let interface = CWWiFiClient.shared().interface(), let ssid = try? interface.ssid() { return ssid }
        return nil
    }

    private func ssidMatches(_ actual: String, _ target: String) -> Bool {
        actual.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(target.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func command(_ path: String, _ arguments: [String]) -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func dayKey(for date: Date = .now) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private func updateTodayStatus() {
        isCheckedInToday = todayCheckIn() != nil
    }

    private func todayCheckIn() -> CheckIn? {
        guard let context else { return nil }
        let key = dayKey()
        let predicate = #Predicate<CheckIn> { $0.dayKey == key }
        return try? context.fetch(FetchDescriptor(predicate: predicate)).first
    }

    private func beginPolling() {
        timer?.invalidate(); timer = nil
        refresh()
        guard todayCheckIn()?.source != "wifi" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Stop Wi-Fi polling once today's record exists, then resume automatically at the next local day.
    private func scheduleNextDay() {
        timer?.invalidate()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now.addingTimeInterval(24 * 60 * 60)
        timer = Timer.scheduledTimer(withTimeInterval: max(1, tomorrow.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginPolling() }
        }
    }

    /// A changed target means today's automatic result must be verified against the new network.
    private func resetTodayForTargetChange() {
        guard let context else { return }
        let key = dayKey(), predicate = #Predicate<CheckIn> { $0.dayKey == key }
        guard let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first else { return }
        context.delete(existing)
        do {
            try context.save()
            isCheckedInToday = false
            automaticStatus = .waiting
            statusText = "Target WiFi changed; checking again"
            _ = try ExportService.export(from: context)
        } catch { lastError = "Could not reset today's check-in: \(error.localizedDescription)" }
    }

    private func checkIn(ssid: String, source: String) {
        guard let context else { return }
        let key = dayKey()
        let predicate = #Predicate<CheckIn> { $0.dayKey == key }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            // Preserve a real automatic result; replace provisional manual/backfill data.
            guard existing.source != "wifi" else {
                isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; scheduleNextDay(); return
            }
            existing.checkedInAt = .now
            existing.ssid = ssid
            existing.source = source
            do {
                try context.save(); isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; _ = try ExportService.export(from: context); scheduleNextDay()
            } catch { automaticStatus = .warning; statusText = "Automatic check-in needs attention"; lastError = "Check-in failed: \(error.localizedDescription)" }
            return
        }
        context.insert(CheckIn(dayKey: key, ssid: ssid, source: source))
        do {
            try context.save(); isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; _ = try ExportService.export(from: context); scheduleNextDay()
        } catch { automaticStatus = .warning; statusText = "Automatic check-in needs attention"; lastError = "Check-in failed: \(error.localizedDescription)" }
    }
}
