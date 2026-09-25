import AppKit
import Foundation
import JevFolderSortCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published private(set) var scope = ScopeConfig()
    @Published private(set) var issues: [ScopeIssue] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var isSorting = false
    @Published private(set) var lastRun: RunRecord?
    @Published private(set) var sortedToday = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var engineStatus = "Not started"
    @Published var alert: String?

    let policy = ScopePolicy.system
    private let db: AppDatabase
    private var engine: EngineClient?
    private var scheduler: Scheduler!

    init() {
        do {
            db = try AppDatabase(path: try AppDatabase.defaultURL().path)
        } catch {
            fatalError("Could not open the app database: \(error)")
        }
        settings = (try? db.settings()) ?? AppSettings()
        if settings.engineDirectory.isEmpty {
            settings.engineDirectory = ProcessInfo.processInfo.environment["JEVSORT_ENGINE"]
                ?? Bundle.main.object(forInfoDictionaryKey: "JEVEngineDirectory") as? String ?? ""
            try? db.save(settings)
        }
        scope = (try? db.scope()) ?? ScopeConfig()
        scheduler = Scheduler(intervalMinutes: settings.intervalMinutes) { [weak self] trigger in
            await self?.runPipeline(trigger: trigger)
        }
        scheduler.paused = settings.paused
        scheduler.start()
        refresh()
    }

    // MARK: sorting

    func sortNow() {
        Task { await scheduler.trigger("manual") }
    }

    private func runPipeline(trigger: String) async {
        guard issues.isEmpty else {
            status = "Set up your scope in Settings"
            return
        }
        isSorting = true
        status = "Sorting…"
        defer { isSorting = false; refresh() }
        do {
            let client = try await startEngineIfNeeded()
            let run = try await Pipeline(db: db, classifier: client, policy: policy).run(trigger: trigger)
            if let error = run.error {
                status = "Last run had a problem"
                engineStatus = error
            } else {
                status = run.candidates == 0 ? "Nothing new" : "Moved \(run.moved), \(run.pending) to review"
            }
        } catch {
            status = "Engine unavailable"
            engineStatus = "\(error)"
        }
    }

    private func startEngineIfNeeded() async throws -> EngineClient {
        if let engine { return engine }
        let launch = try EngineLaunch.development(engineDirectory: settings.engineDirectory, stub: settings.useStubEngine)
        let client = EngineClient(launch: launch)
        engineStatus = "Starting…"
        let health = try await client.start()
        engineStatus = "\(health.model) (\(health.kind)) on \(health.device)"
        engine = client
        return client
    }

    func restartEngine() {
        Task {
            await engine?.stop()
            engine = nil
            do { _ = try await startEngineIfNeeded() } catch { engineStatus = "\(error)" }
        }
    }

    func setPaused(_ paused: Bool) {
        settings.paused = paused
        scheduler.paused = paused
        save(settings)
    }

    // MARK: scope

    /// Every scope change goes through here, is validated, and is saved at once.
    func update(scope newScope: ScopeConfig) {
        scope = newScope
        do { try db.save(newScope) } catch { alert = "Couldn't save scope: \(error)" }
        refresh()
    }

    /// Add a watched folder, refusing protected locations up front.
    func addSource(_ url: URL) {
        guard let path = ScopePaths.canonical(url.path) else { return }
        if let reason = policy.refusal(for: path) { alert = reason; return }
        if scope.folders.contains(where: { scope.resolve($0) == path }) {
            alert = "That folder is a destination. A folder can't be both watched and a destination."
            return
        }
        guard !scope.sources.contains(path) else { return }
        var s = scope
        s.sources.append(path)
        update(scope: s)
    }

    func removeSource(_ path: String) {
        var s = scope
        s.sources.removeAll { $0 == path }
        update(scope: s)
    }

    func setRoot(_ url: URL) {
        guard let path = ScopePaths.canonical(url.path) else { return }
        if let reason = policy.refusal(for: path) { alert = reason; return }
        var s = scope
        if s.root != path {
            s.root = path
            s.folders = []
        }
        s.folders = FolderImport.folders(under: path, merging: s.folders)
        update(scope: s)
    }

    func rescanFolders() {
        guard let root = scope.root else { return }
        var s = scope
        s.folders = FolderImport.folders(under: root, merging: s.folders)
        update(scope: s)
    }

    func setAllowed(_ id: String, _ allowed: Bool) {
        var s = scope
        guard let i = s.folders.firstIndex(where: { $0.id == id }) else { return }
        s.folders[i].allowed = allowed
        update(scope: s)
    }

    func setAllAllowed(_ allowed: Bool) {
        var s = scope
        for i in s.folders.indices { s.folders[i].allowed = allowed }
        update(scope: s)
    }

    func setDescription(_ id: String, _ text: String) {
        var s = scope
        guard let i = s.folders.firstIndex(where: { $0.id == id }), s.folders[i].description != text else { return }
        s.folders[i].description = text
        scope = s
        try? db.save(s)
    }

    // MARK: settings

    func save(_ new: AppSettings) {
        let intervalChanged = new.intervalMinutes != settings.intervalMinutes
        let engineChanged = new.engineDirectory != settings.engineDirectory || new.useStubEngine != settings.useStubEngine
        settings = new
        do { try db.save(new) } catch { alert = "Couldn't save settings: \(error)" }
        if intervalChanged { scheduler.reschedule(intervalMinutes: new.intervalMinutes) }
        if engineChanged { restartEngine() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                alert = "Launch at login needs the app to run from its .app bundle (\(error.localizedDescription))"
            }
            objectWillChange.send()
        }
    }

    // MARK: stats

    func refresh() {
        issues = scope.issues(policy: policy)
        lastRun = try? db.lastRun()
        sortedToday = (try? db.movedCount(since: Calendar.current.startOfDay(for: Date()))) ?? 0
        pendingCount = (try? db.pendingCount()) ?? 0
        history = (try? db.history()) ?? []
        if !isSorting {
            if !issues.isEmpty { status = "Set up your scope in Settings" }
            else if settings.paused { status = "Paused" }
            else if status == "Set up your scope in Settings" || status == "Paused" { status = "Idle" }
        }
    }
}
