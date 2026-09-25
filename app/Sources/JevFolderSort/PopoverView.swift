import JevFolderSortCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("jev-folder-sort").font(.headline)
                Spacer()
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }

            if !model.issues.isEmpty {
                Label(model.issues[0].message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                stat("\(model.sortedToday)", "sorted today")
                stat("\(model.pendingCount)", "to review")
                stat(lastRunText, "last run")
            }

            HStack {
                Button {
                    model.sortNow()
                } label: {
                    Label("Sort now", systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("r")
                .disabled(model.isSorting || !model.issues.isEmpty)

                Button(model.settings.paused ? "Resume" : "Pause") { model.setPaused(!model.settings.paused) }
            }

            Divider()
            HStack {
                Button("Activity…") {
                    bringToFront()
                    openWindow(id: "activity")
                }
                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { bringToFront() })
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    private var dotColor: Color {
        if !model.issues.isEmpty { return .orange }
        if model.settings.paused { return .gray }
        return model.isSorting ? .blue : .green
    }

    private var lastRunText: String {
        guard let at = model.lastRun?.finishedAt else { return "—" }
        return at.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
