import AppKit
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @EnvironmentObject private var service: CheckInService
    @Environment(\.modelContext) private var context
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.isCheckedInToday ? "Checked in today" : "Waiting for automatic check-in").font(.headline)
            Text("Wi‑Fi: \(service.currentWiFi)").foregroundStyle(.secondary)
            Divider()
            Button("Check In Now") { service.manualCheckIn() }
            Button("Export Excel") { do { NSWorkspace.shared.activateFileViewerSelecting([try ExportService.export(from: context)]) } catch { service.report(error) } }
            Button("Refresh Wi‑Fi") { service.refresh() }
            Divider()
            Button("Quit OfficeCheckin") { NSApplication.shared.terminate(nil) }
        }.padding().frame(width: 260)
    }
}
