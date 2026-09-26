import Charts
import JevFolderSortCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .review ? model.pending.count : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.section {
            case .review: ReviewView()
            case .activity: ActivityView()
            case .structure: StructureView()
            case .stats: StatsView()
            }
        }
        .toolbar {
            Button { model.sortNow() } label: { Label("Sort now", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(model.isSorting || !model.issues.isEmpty)
        }
        .alert("jev-folder-sort", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .onAppear { model.refresh(); bringToFront() }
    }
}

// MARK: - Review

struct ReviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.pending) { item in ReviewRow(item: item) }
        }
        .overlay {
            if model.pending.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                       description: Text("Files the model wasn't sure about stay where they are and show up here."))
            }
        }
        .navigationTitle("Review")
        .navigationSubtitle("\(model.pending.count) files waiting")
    }
}

struct ReviewRow: View {
    @EnvironmentObject var model: AppModel
    let item: PendingItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text((item.path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(item.suggestions.prefix(3), id: \.folderPath) { s in
                        if let folder = model.folder(forPath: s.folderPath) {
                            Button("\(s.folderPath)  \(pct(s.p))") { model.file(item, into: folder) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Menu("Move to…") {
                        ForEach(model.scope.allowedFolders) { f in
                            Button(f.relativePath) { model.file(item, into: f) }
                        }
                    }
                    .controlSize(.small).fixedSize()
                    Button("Leave it") { model.ignore(item) }.controlSize(.small)
                    Button { model.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: HistoryEntry.ID?

    var body: some View {
        Table(model.history, selection: $selection) {
            TableColumn("When") { e in Text(e.at.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 120, ideal: 140)
            TableColumn("File", value: \.fileName)
            TableColumn("Result") { e in
                Label(e.undoneAt != nil ? "Undone" : e.status.label, systemImage: e.status.icon)
                    .foregroundStyle(e.undoneAt != nil ? .secondary : e.status.color)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Folder") { e in Text(e.correctedTo.map { "\(e.folderPath ?? "") → \($0)" } ?? e.folderPath ?? "—") }
            TableColumn("Why") { e in
                Text(e.reason == "model" ? "model \(pct(e.confidence))" : e.reason)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Detail") { e in Text(e.detail ?? "").foregroundStyle(.secondary) }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let id = ids.first, let e = model.history.first(where: { $0.id == id }) {
                if e.status == .moved, e.undoneAt == nil {
                    Button("Undo this move") { model.undo(e) }
                    Button("Undo whole run") { model.undoRun(e.runID) }
                }
                if let p = e.destinationPath ?? Optional(e.sourcePath) { Button("Show in Finder") { model.reveal(p) } }
            }
        }
        .toolbar {
            if let id = selection, let e = model.history.first(where: { $0.id == id }), e.status == .moved, e.undoneAt == nil {
                Button { model.undo(e) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
        }
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView("Nothing sorted yet", systemImage: "tray",
                                       description: Text("Moves, suggestions and refusals show up here."))
            }
        }
        .navigationTitle("Activity")
    }
}

extension HistoryEntry.Status {
    var label: String {
        switch self {
        case .moved: "Moved"
        case .pending: "To review"
        case .preview: "Suggested"
        case .refused: "Refused"
        case .undone: "Put back"
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

// MARK: - Structure

struct FolderNode: Identifiable, Hashable {
    let folder: DestinationFolder
    var children: [FolderNode]?
    var id: String { folder.id }
}

func buildTree(_ folders: [DestinationFolder]) -> [FolderNode] {
    func kids(of prefix: String?) -> [FolderNode] {
        folders.filter { f in
            let parent = f.relativePath.contains("/") ? (f.relativePath as NSString).deletingLastPathComponent : nil
            return parent == prefix
        }
        .map { f in
            let c = kids(of: f.relativePath)
            return FolderNode(folder: f, children: c.isEmpty ? nil : c)
        }
    }
    return kids(of: nil)
}

struct StructureView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(buildTree(model.scope.folders), children: \.children, selection: $selection) { node in
                    HStack {
                        Image(systemName: node.folder.allowed ? "folder.fill" : "folder")
                            .foregroundStyle(node.folder.allowed ? Color.accentColor : .secondary)
                        Text((node.folder.relativePath as NSString).lastPathComponent)
                            .foregroundStyle(node.folder.allowed ? .primary : .secondary)
                        Spacer()
                        let n = model.rules(for: node.folder.id).count
                        if n > 0 { Text("\(n) rule\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .tag(node.folder.id)
                }
                Divider()
                HStack {
                    Button { showNew = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        .disabled(model.scope.root == nil)
                    Button("Rescan") { model.rescanFolders() }.disabled(model.scope.root == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 260, idealWidth: 300)

            Group {
                if let id = selection, let folder = model.scope.folders.first(where: { $0.id == id }) {
                    FolderDetail(folder: folder).id(folder.id)
                } else {
                    ContentUnavailableView(model.scope.root == nil ? "Choose a destination root in Settings → Scope" : "Select a folder",
                                           systemImage: "folder.badge.gearshape",
                                           description: Text("Describe what goes in each folder and add rules. Only ticked folders can receive files."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Structure")
        .navigationSubtitle(model.scope.root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
        .sheet(isPresented: $showNew) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New folder").font(.headline)
                Text("Created inside \(selection.flatMap { id in model.scope.folders.first { $0.id == id }?.relativePath } ?? "the destination root").")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { showNew = false; newName = "" }
                    Button("Create") {
                        let parent = selection.flatMap { id in model.scope.folders.first { $0.id == id }?.relativePath }
                        model.createFolder(named: newName, in: parent)
                        showNew = false
                        newName = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FolderEditor.validName(newName))
                }
            }
            .padding(20)
        }
    }
}

struct FolderDetail: View {
    @EnvironmentObject var model: AppModel
    let folder: DestinationFolder
    @State private var description = ""
    @State private var kind: Rule.Kind = .fileExtension
    @State private var pattern = ""

    var body: some View {
        Form {
            Section {
                Toggle("Allowed to receive files", isOn: Binding(get: { folder.allowed }, set: { model.setAllowed(folder.id, $0) }))
                TextField("What goes here?", text: $description, prompt: Text("e.g. bank statements, invoices, tax documents"))
                    .onChange(of: description) { _, v in model.setDescription(folder.id, v) }
                LabeledContent("Path", value: folder.relativePath)
            } header: { Text((folder.relativePath as NSString).lastPathComponent) }
              footer: { Text("A good description helps the model more than anything else.") }

            Section {
                ForEach(model.rules(for: folder.id), id: \.pattern) { rule in
                    HStack {
                        Text(rule.kind.label).foregroundStyle(.secondary)
                        Text(rule.pattern).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) { model.deleteRule(rule) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("", selection: $kind) {
                        ForEach(Rule.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    TextField(kind.placeholder, text: $pattern).onSubmit(add)
                    Button("Add", action: add).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Rules") }
              footer: { Text("A matching rule sends the file here without asking the model (still only within your scope). Deepest folder wins.") }
        }
        .formStyle(.grouped)
        .onAppear { description = folder.description }
    }

    private func add() {
        model.addRule(folderID: folder.id, kind: kind, pattern: pattern)
        pattern = ""
    }
}

extension Rule.Kind {
    var label: String {
        switch self {
        case .fileExtension: "Extension is"
        case .nameGlob: "Name matches"
        case .sourceDomain: "Downloaded from"
        case .contentType: "File type is"
        }
    }

    var placeholder: String {
        switch self {
        case .fileExtension: "pdf, docx"
        case .nameGlob: "Screenshot*"
        case .sourceDomain: "chase.com"
        case .contentType: "public.image"
        }
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    tile("\(s.movedAllTime)", "files sorted")
                    tile("\(s.movedThisWeek)", "this week")
                    tile("\(s.pending)", "to review")
                    tile(s.averageLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—", "per decision")
                }
                HStack(spacing: 12) {
                    tile(autoShare(s), "sorted automatically")
                    tile("\(s.byReason["rule"] ?? 0)", "by rules")
                    tile("\(s.corrections)", "corrections learned")
                    tile("\(s.undone)", "undone")
                }
                if !s.byDay.isEmpty {
                    GroupBox("Last 7 days") {
                        Chart(s.byDay, id: \.day) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Files", d.count))
                        }
                        .frame(height: 160)
                    }
                }
                if !s.byFolder.isEmpty {
                    GroupBox("Top folders") {
                        Chart(s.byFolder, id: \.folder) { f in
                            BarMark(x: .value("Files", f.count), y: .value("Folder", f.folder))
                        }
                        .frame(height: CGFloat(max(80, s.byFolder.count * 26)))
                    }
                }
                GroupBox("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Engine", value: model.engineStatus)
                        LabeledContent("Average confidence of model moves", value: pct(s.averageConfidence))
                        LabeledContent("Personalised", value: model.learning?.personalised == true ? "yes" : "not yet")
                        LabeledContent("Runs", value: "\(s.runs)")
                    }
                }
                Text("Everything here is computed on this Mac from the local history. Nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Stats")
    }

    private func autoShare(_ s: SortStats) -> String {
        let auto = (s.byReason["model"] ?? 0) + (s.byReason["rule"] ?? 0)
        let total = auto + (s.byReason["you"] ?? 0) + s.pending
        return total == 0 ? "—" : "\(auto * 100 / total)%"
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
