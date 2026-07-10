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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.service)
        } label: { Image("MenuBarIcon") }
        .menuBarExtraStyle(.window)
        .modelContainer(appDelegate.container)
    }
}
