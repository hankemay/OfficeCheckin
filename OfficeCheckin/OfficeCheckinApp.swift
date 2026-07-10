import SwiftUI
import SwiftData

@main
struct OfficeCheckinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(appDelegate.service)
        }
        .modelContainer(appDelegate.container)
        .commands { CommandGroup(after: .appInfo) { Button("Export Excel") { _ = try? ExportService.export() } } }

        MenuBarExtra("Office Check-in", systemImage: appDelegate.service.isCheckedInToday ? "checkmark.circle.fill" : "circle") {
            MenuBarView()
                .environmentObject(appDelegate.service)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(appDelegate.container)
    }
}
