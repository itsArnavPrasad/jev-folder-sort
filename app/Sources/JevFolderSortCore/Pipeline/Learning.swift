import Foundation

/// Collects training examples for on-device learning. Read-only: it looks at
/// files inside the allowed destination folders but never moves anything.
public struct LearningCollector: Sendable {
    let db: AppDatabase
    let policy: ScopePolicy

    public init(db: AppDatabase, policy: ScopePolicy = .system) {
        self.db = db
        self.policy = policy
    }

    /// Files already sitting in each allowed folder are examples for free.
    /// Newest `perFolder` visible regular files, top level of each folder only.
    @discardableResult
    public func bootstrap(textLimitKB: Int, perFolder: Int = 25) throws -> Int {
        let scope = try db.scope()
        guard scope.issues(policy: policy).isEmpty else { return 0 }
        let extractor = Extractor(textLimitKB: textLimitKB)
        var added = 0
        for folder in scope.allowedFolders {
            guard let dir = scope.resolve(folder) else { continue }
            for entry in Self.files(in: dir).sorted(by: { $0.mtime > $1.mtime }).prefix(perFolder) {
                try db.add(example: TrainingExample(key: "bootstrap:\(entry.path)", state: extractor.extract(path: entry.path),
                                                    folderID: folder.id, source: "bootstrap"))
                added += 1
            }
        }
        return added
    }

    /// Notice when the user re-files something the app sorted: the file (same
    /// inode) now sits in a *different* allowed folder. That folder becomes the
    /// label. Returns the number of corrections found.
    @discardableResult
    public func detectImplicitCorrections(textLimitKB: Int) throws -> Int {
        let scope = try db.scope()
        guard scope.issues(policy: policy).isEmpty else { return 0 }
        let recent = try db.recentMoves()
        guard !recent.isEmpty else { return 0 }
        var byInode: [Int64: (path: String, folder: DestinationFolder)] = [:]
        for folder in scope.allowedFolders {
            guard let dir = scope.resolve(folder) else { continue }
            for e in Self.files(in: dir) { byInode[e.inode] = (e.path, folder) }
        }
        let extractor = Extractor(textLimitKB: textLimitKB)
        var found = 0
        for m in recent {
            guard let inode = m.destinationInode, let dest = m.destinationPath else { continue }
            if Scanner.entry(dest)?.inode == inode { continue }  // still where we put it
            guard let now = byInode[inode], now.folder.relativePath != m.folderPath else { continue }
            try db.add(example: TrainingExample(key: "implicit:\(m.id!)", state: extractor.extract(path: now.path),
                                                folderID: now.folder.id, source: "implicit"))
            try db.markCorrected(m.id!, to: now.folder.relativePath)
            found += 1
        }
        return found
    }

    static func files(in dir: String) -> [SnapshotEntry] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { Scanner.entry(dir + "/" + $0) }
    }
}
