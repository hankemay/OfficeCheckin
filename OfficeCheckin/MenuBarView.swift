import AppKit
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @EnvironmentObject private var service: CheckInService
    @Environment(\.modelContext) private var context
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.isCheckedInToday ? "今天已打卡" : "今天未打卡").font(.headline)
            Text("Wi‑Fi：\(service.currentWiFi)").foregroundStyle(.secondary)
            Divider()
            Button("立即打卡") { service.manualCheckIn() }
            Button("立即导出 Excel") { ExportService.export(from: context) }
            Button("刷新 Wi‑Fi") { service.refresh() }
            Divider()
            Button("退出 OfficeCheckin") { NSApplication.shared.terminate(nil) }
        }.padding().frame(width: 260)
    }
}
