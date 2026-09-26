import Foundation

/// One sort run: scan → extract → rules → model → confidence gate → ScopeGuard move.
///
/// Anything that isn't a confident, in-scope decision leaves the file where it
/// is and puts it on the Review list. The engine only ever sees folder ids and
/// relative folder names; ScopeGuard maps ids back to real paths.
public final class Pipeline: @unchecked Sendable {
    let db: AppDatabase
    let classifier: FolderClassifier
    let policy: ScopePolicy
    let scanner: Scanner

    public init(db: AppDatabase, classifier: FolderClassifier, policy: ScopePolicy = .system, scanner: Scanner = Scanner()) {
        self.db = db
        self.classifier = classifier
        self.policy = policy
        self.scanner = scanner
    }

    @discardableResult
    public func run(trigger: String) async throws -> RunRecord {
        var run = RunRecord(startedAt: Date(), trigger: trigger)
        run.id = try db.begin(run: run)
        defer { run.finishedAt = Date(); try? db.finish(run: run) }

        let settings = try db.settings()
        let scope = try db.scope()
        let issues = scope.issues(policy: policy)
        guard issues.isEmpty else {
            run.error = "Scope not set up: " + issues.map(\.message).joined(separator: "; ")
            return run
        }
        let guardrail = ScopeGuard(config: scope, policy: policy)
        if settings.learningEnabled {
            _ = try? LearningCollector(db: db, policy: policy).detectImplicitCorrections(textLimitKB: settings.textLimitKB)
        }
        let folders = Dictionary(uniqueKeysWithValues: scope.allowedFolders.map { ($0.id, $0) })

        let scan = try await scanner.scan(sources: scope.sources, snapshot: db.snapshot(under:))
        try db.record(snapshot: [], removing: scan.removed)
        for gone in scan.removed { try db.clearPending(path: gone) }
        run.candidates = scan.candidates.count
        guard !scan.candidates.isEmpty else { return run }

        let extractor = Extractor(textLimitKB: settings.textLimitKB)
        let rules = RuleEngine(rules: try db.rules(), scope: scope)
        var decisions: [String: Decision] = [:]
        var forModel: [(entry: SnapshotEntry, state: FileState)] = []
        for entry in scan.candidates {
            let state = extractor.extract(path: entry.path)
            if let hit = rules.match(state) {
                decisions[entry.path] = Decision(folderID: hit.folderID, confidence: 1, reason: "rule", suggestions: [], latencyMs: nil)
            } else {
                forModel.append((entry, state))
            }
        }

        if !forModel.isEmpty {
            let tree = scope.allowedFolders.map { EngineFolder(id: $0.id, path: $0.relativePath, description: $0.description) }
            let files = forModel.enumerated().map { EngineFile(id: "c\($0.offset)", state: $0.element.state) }
            do {
                let answers = Dictionary(try await classifier.classify(tree: tree, files: files).map { ($0.file, $0) },
                                         uniquingKeysWith: { a, _ in a })
                for (i, item) in forModel.enumerated() {
                    guard let a = answers["c\(i)"] else { continue }
                    let suggestions = a.top.compactMap { s in folders[s.folder].map { ($0.relativePath, s.p) } }
                    decisions[item.entry.path] = Decision(folderID: a.choice, confidence: a.confidence, reason: "model",
                                                          suggestions: suggestions, latencyMs: a.latencyMs)
                }
            } catch {
                // No decision means no move; these files are retried next run.
                run.error = "\(error)"
            }
        }

        var leftInPlace: [SnapshotEntry] = []
        for entry in scan.candidates {
            guard let d = decisions[entry.path] else { continue }
            let name = (entry.path as NSString).lastPathComponent
            var h = HistoryEntry(runID: run.id!, at: Date(), fileName: name, sourcePath: entry.path,
                                 folderPath: folders[d.folderID]?.relativePath, reason: d.reason,
                                 confidence: d.confidence, status: .pending, latencyMs: d.latencyMs)

            let confident = d.folderID != EngineDecision.noneID && folders[d.folderID] != nil
                && d.confidence >= settings.confidenceThreshold
            if !confident || settings.previewMode {
                h.status = confident ? .preview : .pending
                h.detail = d.folderID == EngineDecision.noneID ? "no folder fits"
                    : confident ? "preview mode" : String(format: "confidence %.0f%% below threshold", d.confidence * 100)
                try db.setPending(path: entry.path, runID: run.id!, suggestions: d.suggestions, reason: h.detail!)
                try db.add(history: h)
                leftInPlace.append(entry)
                run.pending += 1
                continue
            }

            switch guardrail.move(sourcePath: entry.path, folderID: d.folderID) {
            case .success(let outcome):
                h.status = .moved
                h.destinationPath = outcome.destinationPath
                h.destinationInode = Scanner.entry(outcome.destinationPath)?.inode
                try db.clearPending(path: entry.path)
                run.moved += 1
            case .failure(let violation):
                h.status = .refused
                h.detail = violation.description
                leftInPlace.append(entry)
                run.refused += 1
            }
            try db.add(history: h)
        }
        // Remember files we decided to leave, so they aren't re-asked until they change.
        try db.record(snapshot: leftInPlace, removing: [])
        return run
    }

    struct Decision {
        var folderID: String
        var confidence: Double
        var reason: String
        var suggestions: [(folderPath: String, p: Double)]
        var latencyMs: Double?
    }
}
