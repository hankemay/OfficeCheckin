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
    @Published private(set) var matchedWiFi: String?
    @Published private(set) var matchedAt: Date?
    @Published private(set) var wifiHint: String?
    @Published private(set) var isCheckedInToday = false
    @Published private(set) var isWorkingDayToday = true
    @Published private(set) var automaticStatus: AutomaticStatus = .waiting
    @Published private(set) var statusText = "Waiting for automatic check-in"
    @Published var lastError: String?
    @Published private(set) var lastImportSummary: String?

    private var timer: Timer?
    private var automaticResumeAfter: Date?
    private var context: ModelContext?
    private let locationManager = CLLocationManager()
    static let targetKey = "targetSSID"
    static let autoExportKey = "autoExportCheckInStats"
    static let launchAtLoginKey = "launchAtLoginEnabled"
    static let defaultSSID = "verizion_QV96NR"

    var targetSSID: String {
        UserDefaults.standard.string(forKey: Self.targetKey) ?? Self.defaultSSID
    }
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    private var launchAtLoginPreferred: Bool { (UserDefaults.standard.object(forKey: Self.launchAtLoginKey) as? Bool) ?? true }
    private var autoExportEnabled: Bool { (UserDefaults.standard.object(forKey: Self.autoExportKey) as? Bool) ?? true }

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
        if launchAtLoginPreferred { enableLaunchAtLogin() }
        beginPolling()
    }

    func refresh() {
        isWorkingDayToday = isWorkingDay(.now)
        guard isWorkingDayToday else {
            automaticResumeAfter = nil
            isCheckedInToday = false
            matchedWiFi = nil
            matchedAt = nil
            automaticStatus = .success
            statusText = "Weekend — check-in not required"
            scheduleNextWorkingDay()
            return
        }
        if let automaticResumeAfter, automaticResumeAfter > .now {
            automaticStatus = .waiting
            statusText = "Automatic check-in resumes in \(max(1, Int(automaticResumeAfter.timeIntervalSinceNow.rounded(.up)))) seconds"
            return
        }
        automaticResumeAfter = nil
        let existing = todayCheckIn()
        isCheckedInToday = existing != nil
        // A manual/backfill result is provisional: a later automatic success replaces it.
        if existing?.source == "wifi" {
            matchedWiFi = existing?.ssid
            matchedAt = existing?.checkedInAt
            updateCurrentWiFi()
            automaticStatus = .success
            statusText = "Checked in today"
            scheduleNextWorkingDay()
            return
        }
        let ssid = updateCurrentWiFi()
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
        guard isWorkingDay(date) else { lastError = "Check-ins are only available on weekdays."; return }
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
        do {
            try context.save(); _ = try ExportService.export(from: context); _ = try ExportService.exportOperations(from: context)
            if key == dayKey() {
                isCheckedInToday = false
                pauseAutomaticCheckInAfterRemoval()
            }
            lastError = nil
        }
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
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = "Could not update the login-item setting: \(error.localizedDescription)" }
    }

    func report(_ error: Error) { lastError = error.localizedDescription }

    /// Imports the Check-ins sheet generated by OfficeCheckin. Existing days are preserved.
    func importCheckIns(from url: URL) {
        guard let context else { lastError = "The local database is unavailable."; return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let rows = try OfficeCheckinXLSXImporter.checkInRows(from: url)
            let existing = Set((try context.fetch(FetchDescriptor<CheckIn>())).map(\.dayKey))
            var knownDays = existing
            var imported = 0
            var skipped = 0
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"

            for row in rows {
                guard let dateText = row["Date"], let date = formatter.date(from: dateText),
                      date <= .now, isWorkingDay(date) else { skipped += 1; continue }
                let key = dayKey(for: date)
                guard !knownDays.contains(key) else { skipped += 1; continue }
                let timestamp = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
                context.insert(CheckIn(dayKey: key, checkedInAt: timestamp, ssid: row["Wi-Fi"] ?? "Imported from Excel", source: "import"))
                context.insert(OperationLog(action: "Imported check-in", dayKey: key))
                knownDays.insert(key)
                imported += 1
            }
            if imported > 0 {
                try context.save()
                _ = try ExportService.export(from: context)
                _ = try ExportService.exportOperations(from: context)
            }
            lastImportSummary = "Imported \(imported) weekday check-in\(imported == 1 ? "" : "s"). Skipped \(skipped)."
            lastError = nil
            refresh()
        } catch {
            lastImportSummary = nil
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

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

    @discardableResult
    private func updateCurrentWiFi() -> String? {
        let ssid = wifiName()
        currentWiFi = ssid ?? "Not connected"
        wifiHint = ssid == nil ? "Allow Location access and keep App Sandbox disabled to read the Wi-Fi name." : nil
        return ssid
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

    private func isWorkingDay(_ date: Date) -> Bool {
        !Calendar.current.isDateInWeekend(date)
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
        guard isWorkingDay(.now) else { return }
        guard todayCheckIn()?.source != "wifi" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func pauseAutomaticCheckInAfterRemoval() {
        timer?.invalidate()
        automaticResumeAfter = .now.addingTimeInterval(30)
        automaticStatus = .waiting
        statusText = "Automatic check-in resumes in 30 seconds"
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginPolling() }
        }
    }

    /// Stop Wi-Fi polling once today's record exists, then resume on the next weekday.
    private func scheduleNextWorkingDay() {
        timer?.invalidate()
        let calendar = Calendar.current
        var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now.addingTimeInterval(24 * 60 * 60)
        while !isWorkingDay(next) {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(24 * 60 * 60)
        }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
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
        guard isWorkingDay(.now) else {
            automaticStatus = .success
            statusText = "Weekend — check-in not required"
            return
        }
        guard let context else { return }
        let key = dayKey()
        let predicate = #Predicate<CheckIn> { $0.dayKey == key }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            // Preserve a real automatic result; replace provisional manual/backfill data.
            guard existing.source != "wifi" else {
                matchedWiFi = existing.ssid
                matchedAt = existing.checkedInAt
                isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; scheduleNextWorkingDay(); return
            }
            existing.checkedInAt = .now
            existing.ssid = ssid
            existing.source = source
            do {
                try context.save(); matchedWiFi = ssid; matchedAt = existing.checkedInAt; isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; try exportAfterSuccessfulCheckIn(context); scheduleNextWorkingDay()
            } catch { automaticStatus = .warning; statusText = "Automatic check-in needs attention"; lastError = "Check-in failed: \(error.localizedDescription)" }
            return
        }
        let newCheckIn = CheckIn(dayKey: key, ssid: ssid, source: source)
        context.insert(newCheckIn)
        do {
            try context.save(); matchedWiFi = ssid; matchedAt = newCheckIn.checkedInAt; isCheckedInToday = true; automaticStatus = .success; statusText = "Checked in today"; try exportAfterSuccessfulCheckIn(context); scheduleNextWorkingDay()
        } catch { automaticStatus = .warning; statusText = "Automatic check-in needs attention"; lastError = "Check-in failed: \(error.localizedDescription)" }
    }

    private func exportAfterSuccessfulCheckIn(_ context: ModelContext) throws {
        guard autoExportEnabled else { return }
        _ = try ExportService.export(from: context)
    }
}

private enum OfficeCheckinXLSXImporter {
    static func checkInRows(from url: URL) throws -> [[String: String]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "xl/worksheets/sheet1.xml"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let xml = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            throw ImportError.invalidWorkbook
        }

        let rowPattern = try NSRegularExpression(pattern: #"<row\b[^>]*>([\s\S]*?)</row>"#)
        let cellPattern = try NSRegularExpression(pattern: #"<c\b[^>]*\br=\"([A-Z]+)[0-9]+\"[^>]*>([\s\S]*?)</c>"#)
        let textPattern = try NSRegularExpression(pattern: #"<t[^>]*>([\s\S]*?)</t>"#)
        let rowMatches = rowPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        let parsedRows: [[String: String]] = rowMatches.map { row in
            let body = String(xml[Range(row.range(at: 1), in: xml)!])
            return Dictionary(uniqueKeysWithValues: cellPattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { cell in
                guard let columnRange = Range(cell.range(at: 1), in: body), let contentRange = Range(cell.range(at: 2), in: body) else { return nil }
                let content = String(body[contentRange])
                let value = textPattern.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: content) else { return nil }
                    return String(content[range]).xmlDecoded
                }.joined()
                return (String(body[columnRange]), value)
            })
        }
        guard let headers = parsedRows.first, headers.values.contains("Date") else { throw ImportError.invalidWorkbook }
        return parsedRows.dropFirst().map { row in
            Dictionary(uniqueKeysWithValues: row.compactMap { column, value in
                headers[column].map { ($0, value) }
            })
        }.filter { !$0.isEmpty }
    }
}

private enum ImportError: LocalizedError {
    case invalidWorkbook
    var errorDescription: String? { "Select an OfficeCheckin .xlsx file with a Check-ins sheet." }
}

private extension String {
    var xmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
