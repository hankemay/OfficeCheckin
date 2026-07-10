import AppKit
import SwiftData

/// Starts automation with the app process, independent of whether a dashboard window is visible.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let service = CheckInService()
    let container: ModelContainer

    override init() {
        do {
            let schema = Schema([CheckIn.self, OperationLog.self])
            let configuration = ModelConfiguration("OfficeCheckin", schema: schema)
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create the local database: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.start(using: container.mainContext)
    }
}
