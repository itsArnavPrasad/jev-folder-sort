import JevFolderSortCore
import SwiftUI

/// First launch: explain the scope and walk through setting it up.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("jev-folder-sort").font(.title.bold())
                    Text("Sorts files into your folders with a small AI model that runs only on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            step(1, "Choose folders to watch", done: !model.scope.sources.isEmpty,
                 detail: model.scope.sources.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "),
                 hint: "Only files sitting directly inside them are ever touched.") {
                Button("Add folder…") {
                    if let url = chooseFolder(prompt: "Watch", message: "Files sitting directly in this folder will be sorted.") {
                        model.addSource(url)
                    }
                }
            }
            step(2, "Choose a destination root", done: model.scope.root != nil,
                 detail: model.scope.root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "",
                 hint: "Files can only be moved into folders inside it.") {
                Button("Choose…") {
                    if let url = chooseFolder(prompt: "Use as root", message: "Files can only ever be moved into folders inside this one.") {
                        model.setRoot(url)
                    }
                }
            }
            step(3, "Tick the folders that may receive files", done: !model.scope.allowedFolders.isEmpty,
                 detail: "\(model.scope.allowedFolders.count) of \(model.scope.folders.count) folders allowed",
                 hint: "Add descriptions and rules any time in the Structure view.") {
                SettingsLink { Text("Open Scope…") }
            }

            GroupBox {
                Toggle(isOn: Binding(get: { model.settings.previewMode }, set: { v in
                    var s = model.settings
                    s.previewMode = v
                    model.save(s)
                })) {
                    VStack(alignment: .leading) {
                        Text("Start in preview mode")
                        Text("Suggest moves in Review without moving anything, until you trust it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !model.issues.isEmpty {
                Label(model.issues[0].message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else {
                Label("Scope is valid. Nothing outside it can be moved.", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            }

            HStack {
                Text("The model never sees paths and has no network access.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Later") { model.finishOnboarding(); done() }
                Button("Done") { model.finishOnboarding(); done() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.issues.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step<A: View>(_ n: Int, _ title: String, done: Bool, detail: String, hint: String,
                               @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.callout).lineLimit(2) }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}
