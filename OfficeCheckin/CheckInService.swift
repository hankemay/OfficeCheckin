import Combine
import CoreLocation
import CoreWLAN
import Foundation
import ServiceManagement
import SwiftData

@MainActor
final class CheckInService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var currentWiFi = "正在检测…"
    @Published private(set) var isCheckedInToday = false
    @Published var lastError: String?

    private var timer: Timer?
    private var context: ModelContext?
    private let locationManager = CLLocationManager()
    static let targetKey = "targetSSID"
    static let defaultSSID = "verizion_QV96NR"

    var targetSSID: String {
        UserDefaults.standard.string(forKey: Self.targetKey) ?? Self.defaultSSID
    }

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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let ssid = wifiName()
        currentWiFi = ssid ?? "未连接"
        updateTodayStatus()
        guard let ssid, ssid == targetSSID else { return }
        checkIn(ssid: ssid, source: "wifi")
    }

    func manualCheckIn() {
        checkIn(ssid: wifiName() ?? "手动打卡", source: "manual")
    }

    func saveTargetSSID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.targetKey)
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = "登录启动设置失败：\(error.localizedDescription)" }
    }

    func report(_ error: Error) { lastError = error.localizedDescription }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    private func wifiName() -> String? {
        if let interface = CWWiFiClient.shared().interface(), let ssid = try? interface.ssid() { return ssid }
        // CoreWLAN can return nil until location access is approved. Use the built-in
        // network utility as a second, non-private API source in non-sandboxed builds.
        let ports = command("/usr/sbin/networksetup", ["-listallhardwareports"]).components(separatedBy: .newlines)
        for (index, line) in ports.enumerated() where line.contains("Hardware Port: Wi-Fi") {
            guard let deviceLine = ports.dropFirst(index + 1).first(where: { $0.hasPrefix("Device:") }) else { continue }
            let device = deviceLine.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            let answer = command("/usr/sbin/networksetup", ["-getairportnetwork", device])
            let prefix = "Current Wi-Fi Network: "
            if answer.hasPrefix(prefix) { return String(answer.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
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
        guard let context else { return }
        let key = dayKey()
        let predicate = #Predicate<CheckIn> { $0.dayKey == key }
        isCheckedInToday = (try? context.fetch(FetchDescriptor(predicate: predicate)).isEmpty == false) ?? false
    }

    private func checkIn(ssid: String, source: String) {
        guard let context else { return }
        let key = dayKey()
        let predicate = #Predicate<CheckIn> { $0.dayKey == key }
        guard (try? context.fetch(FetchDescriptor(predicate: predicate)).isEmpty) != false else {
            isCheckedInToday = true; return
        }
        context.insert(CheckIn(dayKey: key, ssid: ssid, source: source))
        do {
            try context.save(); isCheckedInToday = true; _ = try ExportService.export(from: context)
        } catch { lastError = "保存打卡失败：\(error.localizedDescription)" }
    }
}
