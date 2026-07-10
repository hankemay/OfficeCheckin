import Foundation

struct QuarterSummary: Identifiable {
    let start: Date
    let end: Date
    let checkInCount: Int
    let workingDays: Int
    let weekCount: Int

    var id: Date { start }
    var averagePerWeek: Double { Double(checkInCount) / Double(weekCount) }
    var minimumCheckIns: Int { weekCount * 2 }
    var title: String { "Q\(((Calendar.current.component(.month, from: start) - 1) / 3) + 1) \(Calendar.current.component(.year, from: start))" }

    static func all(from checkins: [CheckIn], through date: Date = .now) -> [QuarterSummary] {
        let calendar = Calendar.current
        guard let first = checkins.map(\.checkedInAt).min(),
              let firstQuarter = calendar.dateInterval(of: .quarter, for: first),
              let currentQuarter = calendar.dateInterval(of: .quarter, for: date) else { return [] }
        var summaries: [QuarterSummary] = []; var cursor = firstQuarter.start
        while cursor <= currentQuarter.start, let interval = calendar.dateInterval(of: .quarter, for: cursor) {
            let count = checkins.filter { interval.contains($0.checkedInAt) }.count
            let workdays = stride(from: interval.start, to: interval.end, by: 86_400).filter { !calendar.isDateInWeekend($0) }.count
            let weeks = max(1, Int(interval.duration / (7 * 86_400)))
            summaries.append(QuarterSummary(start: interval.start, end: interval.end, checkInCount: count, workingDays: workdays, weekCount: weeks))
            guard let next = calendar.date(byAdding: .month, value: 3, to: cursor) else { break }; cursor = next
        }
        return summaries.reversed()
    }
}
