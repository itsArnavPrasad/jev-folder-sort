import JevFolderSortCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            ScopeSettingsView().tabItem { Label("Scope", systemImage: "lock.shield") }
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            EngineSettingsView().tabItem { Label("Engine", systemImage: "cpu") }
        }
        .frame(width: 640, height: 620)
        .alert("jev-folder-sort", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear { bringToFront() }
    }
}

/// The one place that defines what the app may take from and where it may put things.
struct ScopeSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text(model.scope.summary())
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.issues, id: \.message) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if model.issues.isEmpty {
                    Label("Scope is valid. Nothing outside it can be moved.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("What jev-folder-sort is allowed to do")
            }

            Section {
                ForEach(model.scope.sources, id: \.self) { path in
                    HStack {
                        Image(systemName: "eye")
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button(role: .destructive) { model.removeSource(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add folder to watch…") {
                    if let url = chooseFolder(prompt: "Watch", message: "Files sitting directly in this folder will be sorted.") {
                        model.addSource(url)
                    }
                }
            } header: {
                Text("1 · Watched folders")
            } footer: {
                Text("Only files directly inside these folders are sorted. Sub-folders, hidden files and in-progress downloads are never touched.")
            }

            Section {
                HStack {
                    Image(systemName: "folder")
                    Text(model.scope.root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                        .foregroundStyle(model.scope.root == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") {
                        if let url = chooseFolder(prompt: "Use as root", message: "Files can only ever be moved into folders inside this one.") {
                            model.setRoot(url)
                        }
                    }
                }
            } header: {
                Text("2 · Destination root")
            } footer: {
                Text("Every destination must be inside this folder. Protected locations (system folders, ~/Library, iCloud Drive, cloud storage) can't be chosen.")
            }

            Section {
                if model.scope.folders.isEmpty {
                    Text(model.scope.root == nil ? "Choose a root first." : "No sub-folders found. Create the folders you want in Finder, then rescan.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.scope.folders) { folder in
                    FolderRow(folder: folder)
                }
                HStack {
                    Button("Rescan folders") { model.rescanFolders() }.disabled(model.scope.root == nil)
                    Spacer()
                    Button("Allow all") { model.setAllAllowed(true) }
                    Button("Allow none") { model.setAllAllowed(false) }
                }
            } header: {
                Text("3 · Allowed destination folders")
            } footer: {
                Text("Only checked folders can receive files. Folders are never created, renamed or deleted. A description helps the model, e.g. “bank statements, invoices”.")
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let folder: DestinationFolder
    @State private var description = ""

    var body: some View {
        let depth = folder.relativePath.split(separator: "/").count - 1
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { folder.allowed }, set: { model.setAllowed(folder.id, $0) })) {
                Text(folder.relativePath.split(separator: "/").last.map(String.init) ?? folder.relativePath)
                    .foregroundStyle(folder.allowed ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.leading, CGFloat(depth) * 16)
            Spacer()
            TextField("Description (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .disabled(!folder.allowed)
                .onSubmit { model.setDescription(folder.id, description) }
                .onChange(of: description) { _, new in model.setDescription(folder.id, new) }
        }
        .onAppear { description = folder.description }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = Binding(get: { model.settings }, set: { model.save($0) })
        Form {
            Section("Sorting") {
                Picker("Check for new files every", selection: s.intervalMinutes) {
                    ForEach(AppSettings.intervals, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                VStack(alignment: .leading) {
                    Slider(value: s.confidenceThreshold, in: 0.5...0.95, step: 0.05) {
                        Text("Move automatically at confidence ≥ \(Int(model.settings.confidenceThreshold * 100))%")
                    }
                    Text("Files below this stay where they are and appear in the review list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Read up to", selection: s.textLimitKB) {
                    ForEach([0, 1, 2, 4, 8, 16, 32], id: \.self) { kb in
                        Text(kb == 0 ? "No file contents (name + metadata only)" : "First \(kb) KB of text").tag(kb)
                    }
                }
                Toggle("Preview mode — suggest moves but don't move anything", isOn: s.previewMode)
            }
            Section("App") {
                Toggle("Pause sorting", isOn: s.paused)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

struct EngineSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = Binding(get: { model.settings }, set: { model.save($0) })
        Form {
            Section {
                LabeledContent("Status", value: model.engineStatus)
                HStack {
                    TextField("Engine folder", text: s.engineDirectory)
                    Button("Choose…") {
                        if let url = chooseFolder(prompt: "Use", message: "The repository's engine/ folder (after `uv sync`).") {
                            var new = model.settings
                            new.engineDirectory = url.path
                            model.save(new)
                        }
                    }
                }
                Toggle("Use keyword stub instead of the model", isOn: s.useStubEngine)
                Button("Restart engine") { model.restartEngine() }
            } header: {
                Text("Local model")
            } footer: {
                Text("The open-jev model runs on this Mac in a sandbox with no network access and no write access to your files. It only sees file names, metadata and the first few KB of text, and answers with a folder id from your allowed list.")
            }
        }
        .formStyle(.grouped)
    }
}
