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
