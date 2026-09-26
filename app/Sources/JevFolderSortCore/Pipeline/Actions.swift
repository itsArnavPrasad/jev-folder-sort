import Foundation

/// Things the user does from the Review list and Activity window. Every file
/// operation goes through `ScopeGuard`, built from the scope as it is *now*.
public struct Actions: Sendable {
    let db: AppDatabase
    let policy: ScopePolicy

    public init(db: AppDatabase, policy: ScopePolicy = .system) {
        self.db = db
        self.policy = policy
    }

    private func guardrail() throws -> ScopeGuard { ScopeGuard(config: try db.scope(), policy: policy) }

    /// Move a file from the Review list into the folder the user picked.
    /// The choice becomes a training example.
    @discardableResult
    public func file(pendingPath path: String, into folderID: String, textLimitKB: Int) throws -> Result<MoveOutcome, ScopeViolation> {
        let scope = try db.scope()
        let pending = try db.pendingItems().first { $0.path == path }
        let state = Extractor(textLimitKB: textLimitKB).extract(path: path)
        let result = ScopeGuard(config: scope, policy: policy).move(sourcePath: path, folderID: folderID)
        let runID = try db.begin(run: RunRecord(startedAt: Date(), trigger: "review"))
        var run = RunRecord(id: runID, startedAt: Date(), trigger: "review")
        var h = HistoryEntry(runID: runID, at: Date(), fileName: (path as NSString).lastPathComponent, sourcePath: path,
                             folderPath: scope.folders.first { $0.id == folderID }?.relativePath, reason: "you", status: .moved)
        switch result {
        case .success(let outcome):
            h.destinationPath = outcome.destinationPath
            h.destinationInode = Scanner.entry(outcome.destinationPath)?.inode
            try db.clearPending(path: path)
            let source = pending?.reason.hasPrefix("undone") == true ? "refile" : "review"
            try db.add(example: TrainingExample(key: "\(source):\(path):\(Date().timeIntervalSince1970)", state: state,
                                                folderID: folderID, source: source))
            run.moved = 1
        case .failure(let v):
            h.status = .refused
            h.detail = v.description
            run.refused = 1
            if v == .sourceMissing { try db.clearPending(path: path) }
        }
        try db.add(history: h)
        run.finishedAt = Date()
        try db.finish(run: run)
        return result
    }

    /// Leave the file where it is and drop it from the Review list. It won't be
    /// suggested again unless it changes.
    public func ignore(pendingPath path: String) throws {
        try db.clearPending(path: path)
    }

    /// Undo one move. The file goes back into its watched folder and onto the
    /// Review list (so the user can re-file it, which teaches the model).
    @discardableResult
    public func undo(entryID: Int64) throws -> Result<MoveOutcome, ScopeViolation> {
        guard let entry = try db.entry(id: entryID) else { return .failure(.cannotUndo("unknown entry")) }
        let result = try guardrail().undo(entry)
        if case .success(let outcome) = result {
            try db.markUndone(entryID)
            var h = entry
            h.id = nil
            h.at = Date()
            h.status = .undone
            h.detail = "put back in \(((outcome.destinationPath as NSString).deletingLastPathComponent as NSString).lastPathComponent)"
            h.sourcePath = outcome.sourcePath
            h.destinationPath = outcome.destinationPath
            try db.add(history: h)
            // Don't let the next scan re-sort it straight back; ask the user instead.
            if let snap = Scanner.entry(outcome.destinationPath) { try db.record(snapshot: [snap], removing: []) }
            let suggestions = entry.folderPath.map { [(folderPath: $0, p: entry.confidence ?? 0)] } ?? []
            try db.setPending(path: outcome.destinationPath, runID: entry.runID, suggestions: suggestions,
                              reason: "undone — choose the right folder")
        }
        return result
    }

    /// Undo every move of one run, newest first. Returns how many were undone.
    @discardableResult
    public func undo(runID: Int64) throws -> (undone: Int, failed: [String]) {
        var undone = 0
        var failed: [String] = []
        for e in try db.movedEntries(run: runID) {
            switch try undo(entryID: e.id!) {
            case .success: undone += 1
            case .failure(let v): failed.append("\(e.fileName): \(v)")
            }
        }
        return (undone, failed)
    }
}
