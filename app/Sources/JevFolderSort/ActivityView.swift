import JevFolderSortCore
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Table(model.history) {
            TableColumn("When") { e in Text(e.at.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 120, ideal: 140)
            TableColumn("File", value: \.fileName)
            TableColumn("Result") { e in
                Label(e.status.label, systemImage: e.status.icon).foregroundStyle(e.status.color)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Folder") { e in Text(e.folderPath ?? "—") }
            TableColumn("Why") { e in
                Text(e.reason == "rule" ? "rule" : e.confidence.map { "model \(Int($0 * 100))%" } ?? e.reason)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Detail") { e in Text(e.detail ?? "").foregroundStyle(.secondary) }
        }
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView("Nothing sorted yet", systemImage: "tray",
                                       description: Text("Moves, suggestions and refusals show up here."))
            }
        }
        .toolbar {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear { model.refresh() }
    }
}

extension HistoryEntry.Status {
    var label: String {
        switch self {
        case .moved: "Moved"
        case .pending: "To review"
        case .preview: "Suggested"
        case .refused: "Refused"
        case .undone: "Undone"
        }
    }

    var icon: String {
        switch self {
        case .moved: "checkmark.circle"
        case .pending: "questionmark.circle"
        case .preview: "eye"
        case .refused: "xmark.octagon"
        case .undone: "arrow.uturn.backward.circle"
        }
    }

    var color: Color {
        switch self {
        case .moved: .green
        case .pending: .orange
        case .preview: .blue
        case .refused: .red
        case .undone: .secondary
        }
    }
}
