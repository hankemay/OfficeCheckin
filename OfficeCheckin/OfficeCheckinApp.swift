import SwiftUI
import SwiftData

@main
struct OfficeCheckinApp: App {
    let container: ModelContainer = {
        do {
            let schema = Schema([CheckIn.self])
            let configuration = ModelConfiguration("OfficeCheckin", schema: schema)
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create local database: \(error)")
        }
    }()

    @StateObject private var service = CheckInService()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(service)
        }
        .modelContainer(container)
        .commands { CommandGroup(after: .appInfo) { Button("Export Excel") { _ = try? ExportService.export() } } }

        MenuBarExtra("Office Check-in", systemImage: service.isCheckedInToday ? "checkmark.circle.fill" : "circle") {
            MenuBarView()
                .environmentObject(service)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)
    }
}
