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

    private var quarter: DateInterval { Calendar.current.dateInterval(of: .quarter, for: .now)! }
    private var quarterCheckins: [CheckIn] { checkins.filter { quarter.contains($0.checkedInAt) } }
    private var workingDays: Int { stride(from: quarter.start, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count }
    private var weeklyAverage: Double {
        let weeks = Set(quarterCheckins.map { Calendar.current.dateInterval(of: .weekOfYear, for: $0.checkedInAt)?.start }).count
        return weeks == 0 ? 0 : Double(quarterCheckins.count) / Double(weeks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading) { Text("Office Check-in").font(.largeTitle.bold()); Text("仅在本机保存") .foregroundStyle(.secondary) }; Spacer(); Button("立即导出 Excel") { exportAndReveal() } }
            HStack(spacing: 14) {
                MetricCard(title: "Today", value: service.isCheckedInToday ? "✓ 已打卡" : "未打卡")
                MetricCard(title: "Current WiFi", value: service.currentWiFi)
                MetricCard(title: "Working Days（当前季度）", value: "\(quarterCheckins.count) / \(workingDays)")
                MetricCard(title: "Avg / Week", value: String(format: "%.1f", weeklyAverage))
            }
            GroupBox("Heat Map（当前季度）") { HeatMap(dates: Set(quarterCheckins.map(\.dayKey)), interval: quarter).padding(.vertical, 4) }
            GroupBox("设置") { HStack { Text("指定 WiFi"); TextField("SSID", text: $editingSSID).frame(width: 220); Button("保存") { service.saveTargetSSID(editingSSID); storedSSID = editingSSID }; Toggle("登录时启动", isOn: $launchAtLogin).onChange(of: launchAtLogin) { service.setLaunchAtLogin($0) }; Spacer(); Button("立即打卡") { service.manualCheckIn() } }.padding(.vertical, 4) }
            if let error = service.lastError { Text(error).foregroundStyle(.red) }
            Spacer()
        }
        .padding(26).frame(minWidth: 850, minHeight: 470)
        .onAppear { editingSSID = storedSSID; service.start(using: context) }
    }

    private func exportAndReveal() {
        do { NSWorkspace.shared.activateFileViewerSelecting([try ExportService.export(from: context)]) }
        catch { service.report(error) }
    }
}

private struct MetricCard: View { let title: String; let value: String; var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) } }
private struct HeatMap: View {
    let dates: Set<String>; let interval: DateInterval
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let checked = dates.contains(day.formatted(.iso8601.year().month().day()))
                VStack(spacing: 1) { Text(day.formatted(.dateTime.month().day())).font(.caption2); Circle().fill(checked ? .green : .gray.opacity(0.25)).frame(width: 8, height: 8) }
                    .frame(maxWidth: .infinity, minHeight: 30).padding(.vertical, 2).background(checked ? Color.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
    private var days: [Date] { stride(from: interval.start, to: interval.end, by: 86_400).map { $0 } }
}
