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
    @State private var backfillDate = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    @State private var showingRemoveConfirmation = false

    private var quarter: DateInterval { Calendar.current.dateInterval(of: .quarter, for: .now)! }
    private var month: DateInterval { Calendar.current.dateInterval(of: .month, for: .now)! }
    private var year: DateInterval { Calendar.current.dateInterval(of: .year, for: .now)! }
    private var quarterCheckins: [CheckIn] { checkins.filter { quarter.contains($0.checkedInAt) } }
    private var workingDays: Int { stride(from: quarter.start, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count }
    private var weeklyAverage: Double {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let elapsedWorkingDays = stride(from: quarter.start, to: min(end, quarter.end), by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count
        return elapsedWorkingDays == 0 ? 0 : Double(quarterCheckins.count) / (Double(elapsedWorkingDays) / 5)
    }
    private var minimumCheckIns: Int { max(1, Int(quarter.duration / (7 * 86_400))) * 2 }
    private var expectedDaysLeft: Int { minimumCheckIns - quarterCheckins.count }
    private var remainingWorkingDays: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return stride(from: today, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count
    }
    private var expectedDaysColor: Color {
        if expectedDaysLeft <= 0 { return .green }
        if expectedDaysLeft > remainingWorkingDays { return .red }
        if expectedDaysLeft > remainingWorkingDays / 2 { return .yellow }
        return OfficeTheme.ink
    }
    private var expectedDaysNote: String? {
        if expectedDaysLeft <= 0 { return "Quarter target reached" }
        if expectedDaysLeft > remainingWorkingDays { return "Required office attendance cannot be met" }
        if expectedDaysLeft > remainingWorkingDays / 2 { return "Increase office days to meet the target" }
        return nil
    }
    private var quarterHistory: [QuarterSummary] { QuarterSummary.all(from: checkins) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Office Check-in").font(.largeTitle.bold()).foregroundStyle(OfficeTheme.ink)
                    Text("Local automatic Wi-Fi check-in · retries every 5 minutes").foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: service.automaticStatus, text: service.statusText)
                Button("Export Excel") { exportAndReveal() }.buttonStyle(.borderedProminent).tint(OfficeTheme.primary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                MetricCard(title: "Today", value: service.isCheckedInToday ? "Checked in" : "Waiting", valueColor: service.isCheckedInToday ? .green : .yellow)
                MetricCard(title: "Current WiFi", value: service.currentWiFi)
                MetricCard(title: "Working Days (Quarter)", value: "\(quarterCheckins.count) / \(workingDays)")
                MetricCard(title: "Minimum Check-ins", value: "\(minimumCheckIns)")
                MetricCard(title: "Expected Check-in Days Remaining", value: "\(expectedDaysLeft)", valueColor: expectedDaysColor, note: expectedDaysNote)
                MetricCard(title: "Avg / Week", value: String(format: "%.1f", weeklyAverage), valueColor: weeklyAverage <= 2 ? .red : .green)
            }
            GroupBox {
                calendarOverview.padding(.top, 4)
            } label: {
                HStack {
                    Text("Check-in Calendar")
                    Spacer()
                    Picker("Range", selection: $heatRange) {
                        ForEach(HeatRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
            GroupBox("Automation") { HStack { Text("Target WiFi"); TextField("SSID", text: $editingSSID).frame(width: 210); Button("Save") { service.saveTargetSSID(editingSSID); storedSSID = editingSSID }; Toggle("Launch at Login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { service.setLaunchAtLogin($0) }; Spacer(); Button("Check In Now") { service.manualCheckIn() } }.padding(.vertical, 4) }
            DisclosureGroup("Quarter History") {
                VStack(spacing: 6) {
                    ForEach(quarterHistory) { summary in QuarterHistoryRow(summary: summary) }
                }.padding(.top, 6)
            }
            DisclosureGroup("Advanced Manual Operations") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Manual changes are recorded in OfficeCheckin_Operations_Latest.xlsx.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        DatePicker("Past date", selection: $backfillDate, in: ...Date.now, displayedComponents: .date)
                        Spacer()
                        Button("Add Check-in") { service.backfill(date: backfillDate) }
                        Button("Remove Check-in", role: .destructive) { showingRemoveConfirmation = true }
                    }
                }.padding(.top, 6)
            }
            if let hint = service.wifiHint { Label(hint, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(OfficeTheme.primary) }
            if let error = service.lastError { Text(error).foregroundStyle(.red) }
            Spacer()
        }
        .padding(26).frame(minWidth: 900, minHeight: heatRange == .year ? 780 : 600)
        .background(OfficeTheme.background)
        .confirmationDialog("Remove this check-in?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove Check-in", role: .destructive) { service.removeCheckIn(date: backfillDate) }
        } message: { Text("This action will be recorded in the operations audit file.") }
        .onAppear { editingSSID = storedSSID; service.start(using: context); launchAtLogin = service.launchAtLoginEnabled }
    }

    private func exportAndReveal() {
        do { NSWorkspace.shared.activateFileViewerSelecting([try ExportService.export(from: context)]) }
        catch { service.report(error) }
    }

    @ViewBuilder private var calendarOverview: some View {
        let dates = Set(checkins.map(\.dayKey))
        switch heatRange {
        case .month:
            MonthCalendar(interval: month, dates: dates, compact: false)
        case .quarter:
            HStack(alignment: .top, spacing: 12) {
                ForEach(monthIntervals(in: quarter), id: \.start) { MonthCalendar(interval: $0, dates: dates, compact: true) }
            }
        case .year:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(monthIntervals(in: year), id: \.start) { MonthCalendar(interval: $0, dates: dates, compact: true) }
            }
        }
    }

    private func monthIntervals(in interval: DateInterval) -> [DateInterval] {
        let calendar = Calendar.current
        let count = calendar.dateComponents([.month], from: interval.start, to: interval.end).month ?? 0
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: interval.start) else { return nil }
            return calendar.dateInterval(of: .month, for: date)
        }
    }
}

private enum HeatRange: String, CaseIterable, Identifiable { case month = "This Month", quarter = "This Quarter", year = "This Year"; var id: String { rawValue } }
private enum OfficeTheme { static let primary = Color(red: 0.14, green: 0.34, blue: 0.84); static let ink = Color(red: 0.08, green: 0.13, blue: 0.24); static let background = Color(red: 0.96, green: 0.97, blue: 0.99) }
private struct MetricCard: View { let title: String; let value: String; var valueColor: Color = OfficeTheme.ink; var note: String? = nil; var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.7); if let note { Text(note).font(.caption2).foregroundStyle(valueColor).lineLimit(2) } }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading).padding().background(.white, in: RoundedRectangle(cornerRadius: 12)).shadow(color: OfficeTheme.ink.opacity(0.06), radius: 8, y: 3) } }
private struct StatusBadge: View {
    let status: CheckInService.AutomaticStatus; let text: String
    private var color: Color { status == .success ? .green : .yellow }
    var body: some View { Label(text, systemImage: status == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 7).background(color.opacity(0.12), in: Capsule()) }
}
private struct QuarterHistoryRow: View {
    let summary: QuarterSummary
    var body: some View {
        HStack { Text(summary.title).fontWeight(.semibold).frame(width: 86, alignment: .leading); Text("\(summary.checkInCount) / \(summary.workingDays) working days"); Spacer(); Text(String(format: "Avg / Week %.1f", summary.averagePerWeek)).foregroundStyle(summary.averagePerWeek <= 2 ? .red : .green); Text("Target \(summary.minimumCheckIns)").foregroundStyle(.secondary) }
            .font(.caption).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 7))
    }
}
private struct MonthCalendar: View {
    let interval: DateInterval; let dates: Set<String>; let compact: Bool
    private let calendar = Calendar.current
    var body: some View {
        VStack(spacing: 7) {
            Text(interval.start.formatted(.dateTime.year().month(.wide)))
                .font(compact ? .caption.weight(.semibold) : .headline)
                .foregroundStyle(OfficeTheme.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 7) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { Text($0).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 7) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let checked = dates.contains(day.formatted(.iso8601.year().month().day()))
                        VStack(spacing: compact ? 1 : 3) { Text(day.formatted(.dateTime.day())).font(compact ? .caption2 : .caption); Circle().fill(checked ? .green : .gray.opacity(0.22)).frame(width: compact ? 5 : 6, height: compact ? 5 : 6) }
                            .frame(maxWidth: .infinity, minHeight: compact ? 25 : 38).background(checked ? Color.green.opacity(0.12) : .white, in: RoundedRectangle(cornerRadius: compact ? 4 : 6))
                    } else { Color.clear.frame(maxWidth: .infinity, minHeight: compact ? 25 : 38) }
                }
            }
        }
    }
    private var days: [Date] { stride(from: interval.start, to: interval.end, by: 86_400).map { $0 } }
    private var slots: [Date?] { Array(repeating: nil, count: calendar.component(.weekday, from: interval.start) - 1) + days.map(Optional.some) }
}
