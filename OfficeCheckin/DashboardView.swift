import AppKit
import SwiftUI
import SwiftData

struct DashboardView: View {
    @EnvironmentObject private var service: CheckInService
    @Environment(\.modelContext) private var context
    @Query(sort: \CheckIn.dayKey) private var checkins: [CheckIn]
    @AppStorage(CheckInService.targetKey) private var storedSSID = CheckInService.defaultSSID
    @State private var editingSSID = CheckInService.defaultSSID
    @State private var launchAtLogin = false
    @State private var heatRange: HeatRange = .month

    private var quarter: DateInterval { Calendar.current.dateInterval(of: .quarter, for: .now)! }
    private var month: DateInterval { Calendar.current.dateInterval(of: .month, for: .now)! }
    private var heatInterval: DateInterval { heatRange == .month ? month : quarter }
    private var quarterCheckins: [CheckIn] { checkins.filter { quarter.contains($0.checkedInAt) } }
    private var workingDays: Int { stride(from: quarter.start, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count }
    private var weeklyAverage: Double {
        let weeks = Set(quarterCheckins.map { Calendar.current.dateInterval(of: .weekOfYear, for: $0.checkedInAt)?.start }).count
        return weeks == 0 ? 0 : Double(quarterCheckins.count) / Double(weeks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading) { Text("Office Check-in").font(.largeTitle.bold()).foregroundStyle(OfficeTheme.ink); Text("仅在本机保存") .foregroundStyle(.secondary) }; Spacer(); Button("立即导出 Excel") { exportAndReveal() }.buttonStyle(.borderedProminent).tint(OfficeTheme.primary) }
            HStack(spacing: 14) {
                MetricCard(title: "Today", value: service.isCheckedInToday ? "✓ 已打卡" : "未打卡")
                MetricCard(title: "Current WiFi", value: service.currentWiFi)
                MetricCard(title: "Working Days（当前季度）", value: "\(quarterCheckins.count) / \(workingDays)")
                MetricCard(title: "Avg / Week", value: String(format: "%.1f", weeklyAverage))
            }
            GroupBox {
                HeatMap(dates: Set(checkins.map(\.dayKey)), interval: heatInterval).padding(.top, 4)
            } label: {
                HStack {
                    Text("Heat Map（按周）")
                    Spacer()
                    Picker("范围", selection: $heatRange) {
                        ForEach(HeatRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
            GroupBox("设置") { HStack { Text("指定 WiFi"); TextField("SSID", text: $editingSSID).frame(width: 220); Button("保存") { service.saveTargetSSID(editingSSID); storedSSID = editingSSID }; Toggle("登录时启动", isOn: $launchAtLogin).onChange(of: launchAtLogin) { service.setLaunchAtLogin($0) }; Spacer(); Button("立即打卡") { service.manualCheckIn() } }.padding(.vertical, 4) }
            if let hint = service.wifiHint { Label(hint, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(OfficeTheme.primary) }
            if let error = service.lastError { Text(error).foregroundStyle(.red) }
            Spacer()
        }
        .padding(26).frame(minWidth: 820, minHeight: 420)
        .background(OfficeTheme.background)
        .onAppear { editingSSID = storedSSID; service.start(using: context) }
    }

    private func exportAndReveal() {
        do { NSWorkspace.shared.activateFileViewerSelecting([try ExportService.export(from: context)]) }
        catch { service.report(error) }
    }
}

private enum HeatRange: String, CaseIterable, Identifiable { case month = "本月", quarter = "当前季度"; var id: String { rawValue } }
private enum OfficeTheme { static let primary = Color(red: 0.14, green: 0.34, blue: 0.84); static let ink = Color(red: 0.08, green: 0.13, blue: 0.24); static let background = Color(red: 0.96, green: 0.97, blue: 0.99) }
private struct MetricCard: View { let title: String; let value: String; var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).foregroundStyle(OfficeTheme.ink).lineLimit(1).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.white, in: RoundedRectangle(cornerRadius: 12)).shadow(color: OfficeTheme.ink.opacity(0.06), radius: 8, y: 3) } }
private struct HeatMap: View {
    let dates: Set<String>; let interval: DateInterval
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 6) { ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(height: 30) } }
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let checked = dates.contains(day.formatted(.iso8601.year().month().day()))
                        VStack(spacing: 1) { Text(day.formatted(.dateTime.month().day())).font(.caption2); Circle().fill(checked ? OfficeTheme.primary : .gray.opacity(0.25)).frame(width: 7, height: 7) }
                            .frame(width: 43, height: 30).background(checked ? OfficeTheme.primary.opacity(0.12) : .white, in: RoundedRectangle(cornerRadius: 5))
                    } else { Color.clear.frame(width: 43, height: 30) }
                }
            }
        }
    }
    private var days: [Date] { stride(from: interval.start, to: interval.end, by: 86_400).map { $0 } }
    private var slots: [Date?] { Array(repeating: nil, count: Calendar.current.component(.weekday, from: interval.start) - 1) + days.map(Optional.some) }
}
