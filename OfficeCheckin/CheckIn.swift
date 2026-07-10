import Foundation
import SwiftData

@Model
final class CheckIn {
    @Attribute(.unique) var dayKey: String
    var checkedInAt: Date
    var ssid: String
    var source: String

    init(dayKey: String, checkedInAt: Date = .now, ssid: String, source: String = "wifi") {
        self.dayKey = dayKey
        self.checkedInAt = checkedInAt
        self.ssid = ssid
        self.source = source
    }
}

@Model
final class OperationLog {
    var performedAt: Date
    var action: String
    var dayKey: String

    init(action: String, dayKey: String, performedAt: Date = .now) {
        self.action = action
        self.dayKey = dayKey
        self.performedAt = performedAt
    }
}
