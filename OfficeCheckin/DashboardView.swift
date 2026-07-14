import AppKit
import SwiftUI
import SwiftData

struct DashboardView: View {
    @EnvironmentObject private var service: CheckInService
    @Environment(\.modelContext) private var context
    @Query(sort: \CheckIn.dayKey) private var checkins: [CheckIn]
    @Query private var operations: [OperationLog]
    @AppStorage(CheckInService.targetKey) private var storedSSID = CheckInService.defaultSSID
    @AppStorage("displayName") private var displayName = NSUserName()
    @AppStorage(CheckInService.autoExportKey) private var autoExportEnabled = true
    @State private var editingSSID = CheckInService.defaultSSID
    @State private var launchAtLogin = false
    @State private var heatRange: HeatRange = .month
    @State private var backfillDate = Date.now
    @State private var showingRemoveConfirmation = false
    @State private var showingTargetChangeConfirmation = false
    @State private var pendingTargetSSID = ""
    @State private var debuggingInfoExpanded = false
    @State private var isEditingName = false
    @State private var nameDraft = ""

    private var quarter: DateInterval { Calendar.current.dateInterval(of: .quarter, for: .now)! }
    private var month: DateInterval { Calendar.current.dateInterval(of: .month, for: .now)! }
    private var year: DateInterval { Calendar.current.dateInterval(of: .year, for: .now)! }
    private var quarterCheckins: [CheckIn] { checkins.filter { quarter.contains($0.checkedInAt) && !Calendar.current.isDateInWeekend($0.checkedInAt) } }
    private var workingDays: Int { stride(from: quarter.start, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count }
    private var weeklyAverage: Double {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let elapsedWorkingDays = stride(from: quarter.start, to: min(end, quarter.end), by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count
        return elapsedWorkingDays == 0 ? 0 : Double(quarterCheckins.count) / (Double(elapsedWorkingDays) / 5)
    }
    private var minimumCheckIns: Int { max(1, Int(quarter.duration / (7 * 86_400))) * 2 }
    /// A progress metric should never show a negative number once the target is met.
    private var checkInDaysRemaining: Int { max(0, minimumCheckIns - quarterCheckins.count) }
    private var remainingWorkingDays: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return stride(from: today, to: quarter.end, by: 86_400).filter { !Calendar.current.isDateInWeekend($0) }.count
    }
    private var expectedDaysColor: Color {
        if checkInDaysRemaining == 0 { return .green }
        if checkInDaysRemaining > remainingWorkingDays { return .red }
        if checkInDaysRemaining > remainingWorkingDays / 2 { return .yellow }
        return OfficeTheme.ink
    }
    private var expectedDaysNote: String? {
        if checkInDaysRemaining == 0 { return "Quarter target reached" }
        if checkInDaysRemaining > remainingWorkingDays { return "Required office attendance cannot be met" }
        if checkInDaysRemaining > remainingWorkingDays / 2 { return "Increase office days to meet the target" }
        return nil
    }
    private var quarterHistory: [QuarterSummary] { QuarterSummary.all(from: checkins) }
    private var todayMetricTitle: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MM/dd/yyyy, EEEE"
        return "Today (\(formatter.string(from: .now)))"
    }
    private var quarterProgressLabel: String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: quarter.start)
        let number = (calendar.component(.month, from: quarter.start) - 1) / 3 + 1
        return "Quarter Progress · \(year) Q\(number)"
    }
    private var matchedWiFiNote: String? {
        guard let ssid = service.matchedWiFi else { return nil }
        guard let date = service.matchedAt else { return "Matched Wi-Fi: \(ssid)" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return "Matched Wi-Fi: \(ssid)\nAt: \(formatter.string(from: date))"
    }
    private var calendarStates: [String: CalendarDayState] {
        var events: [(date: Date, dayKey: String, state: CalendarDayState)] = []
        for checkIn in checkins where !Calendar.current.isDateInWeekend(checkIn.checkedInAt) {
            events.append((checkIn.checkedInAt, checkIn.dayKey, checkIn.source == "wifi" ? .checkedIn : .backfilled))
        }
        for operation in operations {
            let state: CalendarDayState = operation.action.hasPrefix("Removed") ? .removed : .backfilled
            events.append((operation.performedAt, operation.dayKey, state))
        }
        return events.sorted { $0.date < $1.date }.reduce(into: [:]) { result, event in result[event.dayKey] = event.state }
    }
    private var recentOperations: [OperationLog] { operations.sorted { $0.performedAt > $1.performedAt }.prefix(10).map { $0 } }
    private var canBackfillSelectedDate: Bool { !Calendar.current.isDateInWeekend(backfillDate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Office Check-in").font(.largeTitle.bold()).foregroundStyle(OfficeTheme.ink)
                    Text("Local automatic Wi-Fi check-in · retries every 5 minutes").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        if isEditingName {
                            TextField("Name", text: $nameDraft).textFieldStyle(.roundedBorder).frame(width: 160)
                            Button("Save") { saveName() }
                            Button("Cancel") { isEditingName = false }
                        } else {
                            Text(displayName).font(.subheadline)
                            Button("Edit") { nameDraft = displayName; isEditingName = true }
                        }
                        Divider().frame(height: 18)
                        Toggle("Launch at Login", isOn: $launchAtLogin).toggleStyle(.checkbox).onChange(of: launchAtLogin) { service.setLaunchAtLogin($0) }
                        Toggle("Auto Export Stats to Excel", isOn: $autoExportEnabled).toggleStyle(.checkbox)
                    }
                }
                Spacer()
                StatusBadge(status: service.automaticStatus, text: service.statusText)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                MetricCard(title: todayMetricTitle, value: service.isWorkingDayToday ? (service.isCheckedInToday ? "Checked in" : "Not checked in today") : "No check-in required", valueColor: service.isWorkingDayToday ? (service.isCheckedInToday ? .green : .yellow) : OfficeTheme.muted, note: service.isCheckedInToday ? matchedWiFiNote : nil, noteColor: OfficeTheme.muted)
                MetricCard(title: "Current WiFi", value: service.currentWiFi)
            }
            GroupBox {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    MetricCard(title: "Checked-in Days", value: "\(quarterCheckins.count)")
                    MetricCard(title: "Check-in Days Remaining", value: "\(checkInDaysRemaining)", valueColor: expectedDaysColor, note: expectedDaysNote)
                    MetricCard(title: "Minimum Required Check-ins", value: "\(minimumCheckIns)")
                    MetricCard(title: "Quarter Workdays", value: "\(workingDays)")
                    MetricCard(title: "Workdays Remaining", value: "\(remainingWorkingDays)", note: "Includes today", noteColor: OfficeTheme.muted)
                    MetricCard(title: "Avg / Week", value: String(format: "%.1f", weeklyAverage), valueColor: weeklyAverage <= 2 ? .red : .green)
                }
                .padding(.top, 4)
            } label: {
                Text(quarterProgressLabel)
            }
            GroupBox {
                calendarOverview.padding(.top, 4)
                HStack(spacing: 12) {
                    Label("Automatic check-in", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("Manual backfill / removal", systemImage: "circle.fill").foregroundStyle(.blue)
                }.font(.caption).padding(.top, 8)
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
            DisclosureGroup("Target WiFi Settings for Check-in") {
                HStack { Text("Target WiFi"); TextField("SSID", text: $editingSSID).frame(width: 210); Button("Save") { saveTargetSSID() } }.padding(.top, 8)
            }
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
                        if !canBackfillSelectedDate { Text("Weekdays only").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Add Check-in") { service.backfill(date: backfillDate) }.buttonStyle(.borderedProminent).tint(OfficeTheme.action).disabled(!canBackfillSelectedDate)
                        Button("Remove Check-in") { showingRemoveConfirmation = true }.buttonStyle(.borderedProminent).tint(OfficeTheme.action)
                    }
                    Button("Export Check-in Status to Excel") { exportAndReveal() }.buttonStyle(.borderedProminent).tint(OfficeTheme.action)
                    if !recentOperations.isEmpty {
                        Divider()
                        Text("Recent Operations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(recentOperations, id: \.persistentModelID) { operation in
                            OperationRow(operation: operation)
                        }
                    }
                }.padding(.top, 6)
            }
            DisclosureGroup("Debugging Info", isExpanded: $debuggingInfoExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(service.isCheckedInToday ? "Check-in successful" : "Check-in unsuccessful", systemImage: service.isCheckedInToday ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(service.isCheckedInToday ? .green : .yellow)
                    Divider()
                    LabeledContent("Current Wi-Fi") { Text(service.currentWiFi) }
                    LabeledContent("Target Wi-Fi") { Text(service.targetSSID) }
                    if let hint = service.wifiHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                    if let error = service.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(.top, 6)
            }
            Spacer()
        }
        .padding(26).frame(minWidth: 900, minHeight: heatRange == .year ? 780 : 600)
        .background(OfficeTheme.background)
        .confirmationDialog("Remove this check-in?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove Check-in", role: .destructive) { service.removeCheckIn(date: backfillDate) }
        } message: { Text("This action will be recorded in the operations audit file.") }
        .confirmationDialog("Change Target WiFi?", isPresented: $showingTargetChangeConfirmation, titleVisibility: .visible) {
            Button("Change Target WiFi", role: .destructive) { service.saveTargetSSID(pendingTargetSSID); storedSSID = pendingTargetSSID; editingSSID = pendingTargetSSID }
            Button("Cancel", role: .cancel) { editingSSID = storedSSID }
        } message: { Text("Changing the target WiFi will clear today's existing check-in result and immediately check again. Please proceed carefully.") }
        .onAppear { editingSSID = storedSSID; launchAtLogin = service.launchAtLoginEnabled; nameDraft = displayName; debuggingInfoExpanded = false; service.refresh() }
    }

    private func exportAndReveal() {
        do { NSWorkspace.shared.activateFileViewerSelecting([try ExportService.export(from: context)]) }
        catch { service.report(error) }
    }

    private func saveTargetSSID() {
        let proposed = editingSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposed.caseInsensitiveCompare(storedSSID.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            service.saveTargetSSID(proposed); return
        }
        pendingTargetSSID = proposed
        showingTargetChangeConfirmation = true
    }

    private func saveName() {
        let value = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { displayName = value }
        isEditingName = false
    }

    @ViewBuilder private var calendarOverview: some View {
        switch heatRange {
        case .month:
            MonthCalendar(interval: month, states: calendarStates, compact: false)
        case .quarter:
            HStack(alignment: .top, spacing: 12) {
                ForEach(monthIntervals(in: quarter), id: \.start) { MonthCalendar(interval: $0, states: calendarStates, compact: true) }
            }
        case .year:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(monthIntervals(in: year), id: \.start) { MonthCalendar(interval: $0, states: calendarStates, compact: true) }
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
private enum CalendarDayState: Equatable { case checkedIn, backfilled, removed }
private enum OfficeTheme { static let primary = Color(red: 0.14, green: 0.34, blue: 0.84); static let action = Color(red: 0.23, green: 0.45, blue: 0.78); static let ink = Color(red: 0.08, green: 0.13, blue: 0.24); static let muted = Color(red: 0.42, green: 0.46, blue: 0.54); static let background = Color(red: 0.96, green: 0.97, blue: 0.99) }
private struct MetricCard: View { let title: String; let value: String; var valueColor: Color = OfficeTheme.ink; var note: String? = nil; var noteColor: Color? = nil; var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).foregroundStyle(valueColor).lineLimit(1).minimumScaleFactor(0.7); if let note { Text(note).font(.caption2).foregroundStyle(noteColor ?? valueColor).lineLimit(2) } }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading).padding().background(.white, in: RoundedRectangle(cornerRadius: 12)).shadow(color: OfficeTheme.ink.opacity(0.06), radius: 8, y: 3) } }
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
private struct OperationRow: View {
    let operation: OperationLog
    var body: some View {
        HStack { Text(operation.action).fontWeight(.medium); Spacer(); Text(operation.dayKey); Text(operation.performedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
            .font(.caption).padding(.vertical, 3)
    }
}
private struct MonthCalendar: View {
    let interval: DateInterval; let states: [String: CalendarDayState]; let compact: Bool
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
                        let key = day.formatted(.iso8601.year().month().day())
                        let state = states[key]
                        let operationLabel = state == .backfilled ? "B" : state == .removed ? "R" : ""
                        let color: Color = state == .checkedIn ? .green : state == nil ? .gray.opacity(0.22) : .blue
                        VStack(spacing: compact ? 1 : 3) {
                            HStack(spacing: 2) { Text(day.formatted(.dateTime.day())).font(compact ? .caption2 : .caption); if !operationLabel.isEmpty { Text(operationLabel).font(.system(size: compact ? 7 : 9, weight: .bold)).foregroundStyle(.blue) } }
                            Circle().fill(color).frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                        }
                            .frame(maxWidth: .infinity, minHeight: compact ? 25 : 38).background(state == .checkedIn ? Color.green.opacity(0.12) : state == nil ? .white : Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 4 : 6))
                    } else { Color.clear.frame(maxWidth: .infinity, minHeight: compact ? 25 : 38) }
                }
            }
        }
    }
    private var days: [Date] { stride(from: interval.start, to: interval.end, by: 86_400).map { $0 } }
    private var slots: [Date?] { Array(repeating: nil, count: calendar.component(.weekday, from: interval.start) - 1) + days.map(Optional.some) }
}
