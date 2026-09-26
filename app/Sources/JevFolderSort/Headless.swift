import Foundation
import JevFolderSortCore

/// Scriptable, window-less mode for end-to-end tests and CI:
///
///   JEVSORT_DATA_DIR=<dir> JevFolderSort --headless [--demo <demoDir>] [--stub] [--preview]
///                                      [--sort] [--train] [--undo-last-run]
///                                      [--learn-from <root> [--per-folder N] [--apply-threshold]]
///
/// `--demo` points the scope at <demoDir>/Inbox and <demoDir>/Sorted (all
/// sub-folders allowed). Requires JEVSORT_DATA_DIR so it never touches the
/// real app data. Prints a JSON summary and exits.
enum Headless {
    static func run(_ args: [String]) -> Never {
        guard let dataDir = ProcessInfo.processInfo.environment["JEVSORT_DATA_DIR"], !dataDir.isEmpty else {
            FileHandle.standardError.write(Data("--headless needs JEVSORT_DATA_DIR (keeps tests away from your real data)\n".utf8))
            exit(2)
        }
        _ = dataDir
        Task {
            do {
                let summary = try await perform(args)
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func perform(_ args: [String]) async throws -> [String: Any] {
        let dataDir = try AppDatabase.dataDirectory()
        let db = try AppDatabase(path: dataDir.appendingPathComponent("app.sqlite").path)
        let policy = ScopePolicy.system
        var settings = try db.settings()
        if settings.engineDirectory.isEmpty {
            settings.engineDirectory = ProcessInfo.processInfo.environment["JEVSORT_ENGINE"]
                ?? Bundle.main.object(forInfoDictionaryKey: "JEVEngineDirectory") as? String ?? ""
        }
        settings.useStubEngine = args.contains("--stub")
        if args.contains("--preview") { settings.previewMode = true }
        try db.save(settings)

        if let demo = value(after: "--demo", in: args) {
            let inbox = try require(ScopePaths.canonical(demo + "/Inbox"), "no Inbox in \(demo)")
            let root = try require(ScopePaths.canonical(demo + "/Sorted"), "no Sorted in \(demo)")
            var scope = try db.scope()
            scope.sources = [inbox]
            if scope.root != root { scope.folders = [] }
            scope.root = root
            scope.folders = FolderImport.folders(under: root, merging: scope.folders)
            try db.save(scope)
        }
        if let root = value(after: "--learn-from", in: args) {
            // Learn-only scope: every sub-folder of <root> is a label. Nothing is
            // watched in a way that matters because this mode never sorts.
            let croot = try require(ScopePaths.canonical(root), "\(root) doesn't exist")
            var scope = try db.scope()
            if scope.root != croot { scope.folders = [] }
            scope.root = croot
            if scope.sources.isEmpty { scope.sources = [croot] }
            scope.folders = FolderImport.folders(under: croot, merging: scope.folders)
            try db.save(scope)
        }
        let scope = try db.scope()
        var out: [String: Any] = ["scope_issues": scope.issues(policy: policy).map(\.message),
                                  "scope_summary": scope.summary()]

        let models = dataDir.appendingPathComponent("models").path
        let launch = try EngineLaunch.bundled(modelDirectory: models, stub: settings.useStubEngine)
            ?? EngineLaunch.development(engineDirectory: settings.engineDirectory, stub: settings.useStubEngine,
                                        modelDirectory: models)
        out["engine_bundled"] = EngineLaunch.bundled(modelDirectory: models, stub: false) != nil

        if args.contains("--sort") {
            let client = EngineClient(launch: launch)
            let health = try await client.start()
            out["engine"] = "\(health.model) (\(health.kind)) on \(health.device)"
            let run = try await Pipeline(db: db, classifier: client, policy: policy).run(trigger: "headless")
            await client.stop()
            out["run"] = ["candidates": run.candidates, "moved": run.moved, "pending": run.pending,
                          "refused": run.refused, "error": run.error as Any]
            out["moves"] = try db.history(limit: 200).filter { $0.runID == run.id }.map {
                ["file": $0.fileName, "status": $0.status.rawValue, "folder": $0.folderPath ?? "",
                 "confidence": $0.confidence ?? -1, "reason": $0.reason, "detail": $0.detail ?? ""]
            }
        }
        if args.contains("--undo-last-run"), let last = try db.history(limit: 500).first(where: { $0.status == .moved })?.runID {
            let r = try Actions(db: db, policy: policy).undo(runID: last)
            out["undo"] = ["undone": r.undone, "failed": r.failed]
        }
        if args.contains("--train") || args.contains("--learn-from") {
            let perFolder = args.contains("--learn-from") ? Int(value(after: "--per-folder", in: args) ?? "") ?? 100 : nil
            let report = try await Learner(db: db, policy: policy, launch: launch).train(learnFromFolders: perFolder)
            out["train"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
            if args.contains("--apply-threshold"), report.activated, let t = report.suggestedThreshold {
                var s = try db.settings()
                s.confidenceThreshold = t
                try db.save(s)
                out["threshold_applied"] = t
            }
            out["user_model"] = launch.activeCheckpoint as Any
        }
        return out
    }

    static func require<T>(_ v: T?, _ message: String) throws -> T {
        guard let v else { throw NSError(domain: "jevsort", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return v
    }
}
