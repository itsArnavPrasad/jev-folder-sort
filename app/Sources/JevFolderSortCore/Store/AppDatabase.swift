import Foundation
import GRDB

public struct AppSettings: Equatable, Sendable {
    public static let intervals = [5, 10, 15]

    public var intervalMinutes = 10
    public var confidenceThreshold = 0.9
    public var textLimitKB = 4
    public var previewMode = false
    public var paused = false
    public var engineDirectory = ""
    public var useStubEngine = false
    public var learningEnabled = true
    public var onboardingDone = false

    public init() {}
}

public struct Rule: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case fileExtension = "extension", nameGlob = "glob", sourceDomain = "domain", contentType = "uti"
    }

    public var id: Int64?
    public var folderID: String
    public var kind: Kind
    public var pattern: String

    public init(id: Int64? = nil, folderID: String, kind: Kind, pattern: String) {
        self.id = id
        self.folderID = folderID
        self.kind = kind
        self.pattern = pattern
    }
}

public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case moved, refused, preview, pending, undone }

    public var id: Int64?
    public var runID: Int64
    public var at: Date
    public var fileName: String
    public var sourcePath: String
    public var destinationPath: String?
    public var folderPath: String?
    public var reason: String  // "rule", "model"
    public var confidence: Double?
    public var status: Status
    public var detail: String?
    public var destinationInode: Int64?
    public var latencyMs: Double?
    public var undoneAt: Date?
    public var correctedTo: String?

    public init(id: Int64? = nil, runID: Int64, at: Date, fileName: String, sourcePath: String,
                destinationPath: String? = nil, folderPath: String? = nil, reason: String, confidence: Double? = nil,
                status: Status, detail: String? = nil, destinationInode: Int64? = nil, latencyMs: Double? = nil,
                undoneAt: Date? = nil, correctedTo: String? = nil) {
        self.id = id; self.runID = runID; self.at = at; self.fileName = fileName; self.sourcePath = sourcePath
        self.destinationPath = destinationPath; self.folderPath = folderPath; self.reason = reason
        self.confidence = confidence; self.status = status; self.detail = detail
        self.destinationInode = destinationInode; self.latencyMs = latencyMs; self.undoneAt = undoneAt
        self.correctedTo = correctedTo
    }
}

public struct PendingItem: Equatable, Sendable, Identifiable {
    public struct Suggestion: Equatable, Sendable { public var folderPath: String; public var p: Double }
    public var id: String { path }
    public var path: String
    public var at: Date
    public var reason: String
    public var suggestions: [Suggestion]
}

public struct SortStats: Equatable, Sendable {
    public var movedAllTime = 0
    public var movedThisWeek = 0
    public var movedToday = 0
    public var pending = 0
    public var refused = 0
    public var undone = 0
    public var corrections = 0
    public var byReason: [String: Int] = [:]  // rule / model / you
    public var byFolder: [(folder: String, count: Int)] = []
    public var byDay: [(day: Date, count: Int)] = []
    public var averageConfidence: Double?
    public var averageLatencyMs: Double?
    public var runs = 0

    public init() {}

    public static func == (a: SortStats, b: SortStats) -> Bool {
        a.movedAllTime == b.movedAllTime && a.movedThisWeek == b.movedThisWeek && a.pending == b.pending
            && a.byReason == b.byReason && a.byFolder.map(\.folder) == b.byFolder.map(\.folder)
    }
}

public struct TrainingExample: Equatable, Sendable {
    public var key: String
    public var state: FileState
    public var folderID: String
    public var source: String  // bootstrap, review, refile, implicit
}

public struct RunRecord: Equatable, Sendable {
    public var id: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var trigger: String
    public var candidates = 0
    public var moved = 0
    public var pending = 0
    public var refused = 0
    public var error: String?
}

public struct SnapshotEntry: Equatable, Sendable {
    public var path: String
    public var inode: Int64
    public var size: Int64
    public var mtime: Double
}

/// All app state, in one SQLite file under Application Support.
public final class AppDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue

    /// `~/Library/Application Support/jev-folder-sort`, or `$JEVSORT_DATA_DIR`
    /// (used for testing so a test launch never touches the real app data).
    public static func dataDirectory() throws -> URL {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["JEVSORT_DATA_DIR"], !custom.isEmpty {
            dir = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("jev-folder-sort", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func defaultURL() throws -> URL {
        try dataDirectory().appendingPathComponent("app.sqlite")
    }

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(queue)
    }

    /// In-memory database for tests.
    public init() throws {
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE source_folder (path TEXT PRIMARY KEY, position INTEGER NOT NULL);
            CREATE TABLE dest_folder (
                id TEXT PRIMARY KEY, relpath TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '',
                allowed INTEGER NOT NULL DEFAULT 1, position INTEGER NOT NULL);
            CREATE TABLE rule (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                folder_id TEXT NOT NULL REFERENCES dest_folder(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, pattern TEXT NOT NULL, position INTEGER NOT NULL);
            CREATE TABLE snapshot (
                path TEXT PRIMARY KEY, inode INTEGER NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL);
            CREATE TABLE run (
                id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, finished_at REAL,
                trigger TEXT NOT NULL, candidates INTEGER NOT NULL DEFAULT 0, moved INTEGER NOT NULL DEFAULT 0,
                pending INTEGER NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0, error TEXT);
            CREATE TABLE move_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER NOT NULL REFERENCES run(id),
                at REAL NOT NULL, file_name TEXT NOT NULL, source_path TEXT NOT NULL, dest_path TEXT,
                folder_path TEXT, reason TEXT NOT NULL, confidence REAL, status TEXT NOT NULL, detail TEXT,
                undone_at REAL);
            CREATE INDEX move_history_at ON move_history(at);
            CREATE TABLE pending_review (
                path TEXT PRIMARY KEY, run_id INTEGER NOT NULL, at REAL NOT NULL,
                suggestions TEXT NOT NULL, reason TEXT NOT NULL);
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            ALTER TABLE move_history ADD COLUMN dest_inode INTEGER;
            ALTER TABLE move_history ADD COLUMN latency_ms REAL;
            ALTER TABLE move_history ADD COLUMN corrected_to TEXT;
            CREATE TABLE training_example (
                id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, key TEXT NOT NULL UNIQUE,
                state TEXT NOT NULL, folder_id TEXT NOT NULL, source TEXT NOT NULL);
            """)
        }
        return m
    }

    // MARK: settings

    public func settings() throws -> AppSettings {
        let kv = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, value FROM setting").map {
                ($0["key"] as String, $0["value"] as String)
            })
        }
        var s = AppSettings()
        if let v = kv["interval"].flatMap(Int.init), AppSettings.intervals.contains(v) { s.intervalMinutes = v }
        if let v = kv["threshold"].flatMap(Double.init) { s.confidenceThreshold = min(max(v, 0.5), 0.99) }
        if let v = kv["textLimitKB"].flatMap(Int.init) { s.textLimitKB = min(max(v, 0), 64) }
        s.previewMode = kv["previewMode"] == "1"
        s.paused = kv["paused"] == "1"
        s.engineDirectory = kv["engineDirectory"] ?? ""
        s.useStubEngine = kv["useStubEngine"] == "1"
        s.learningEnabled = kv["learningEnabled"] != "0"
        s.onboardingDone = kv["onboardingDone"] == "1"
        return s
    }

    public func save(_ s: AppSettings) throws {
        let kv: [String: String] = [
            "interval": String(s.intervalMinutes), "threshold": String(s.confidenceThreshold),
            "textLimitKB": String(s.textLimitKB), "previewMode": s.previewMode ? "1" : "0",
            "paused": s.paused ? "1" : "0", "engineDirectory": s.engineDirectory,
            "useStubEngine": s.useStubEngine ? "1" : "0",
            "learningEnabled": s.learningEnabled ? "1" : "0", "onboardingDone": s.onboardingDone ? "1" : "0",
        ]
        try queue.write { db in
            for (k, v) in kv {
                try db.execute(sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [k, v])
            }
        }
    }

    // MARK: scope

    public func scope() throws -> ScopeConfig {
        try queue.read { db in
            let sources = try String.fetchAll(db, sql: "SELECT path FROM source_folder ORDER BY position")
            let root = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'scope.root'")
            let folders = try Row.fetchAll(db, sql: "SELECT * FROM dest_folder ORDER BY position").map {
                DestinationFolder(id: $0["id"], relativePath: $0["relpath"], description: $0["description"], allowed: $0["allowed"])
            }
            return ScopeConfig(sources: sources, root: root, folders: folders)
        }
    }

    /// Replace the whole scope. Rules for folders that disappear are deleted with them.
    public func save(_ scope: ScopeConfig) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM source_folder")
            for (i, s) in scope.sources.enumerated() {
                try db.execute(sql: "INSERT INTO source_folder(path, position) VALUES (?, ?)", arguments: [s, i])
            }
            if let root = scope.root {
                try db.execute(sql: "INSERT INTO setting(key, value) VALUES ('scope.root', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [root])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = 'scope.root'")
            }
            let ids = scope.folders.map(\.id)
            try db.execute(sql: "DELETE FROM dest_folder WHERE id NOT IN (\(ids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(ids))
            // Two passes so renames that swap relpaths don't trip the UNIQUE constraint.
            try db.execute(sql: "UPDATE dest_folder SET relpath = '__tmp__' || id")
            for (i, f) in scope.folders.enumerated() {
                try db.execute(sql: """
                    INSERT INTO dest_folder(id, relpath, description, allowed, position) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET relpath = excluded.relpath, description = excluded.description,
                        allowed = excluded.allowed, position = excluded.position
                    """, arguments: [f.id, f.relativePath, f.description, f.allowed, i])
            }
        }
    }

    // MARK: rules

    public func rules() throws -> [Rule] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM rule ORDER BY position, id").compactMap { row in
                guard let kind = Rule.Kind(rawValue: row["kind"]) else { return nil }
                return Rule(id: row["id"], folderID: row["folder_id"], kind: kind, pattern: row["pattern"])
            }
        }
    }

    public func save(rules: [Rule]) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM rule")
            for (i, r) in rules.enumerated() {
                try db.execute(sql: "INSERT INTO rule(folder_id, kind, pattern, position) VALUES (?, ?, ?, ?)",
                               arguments: [r.folderID, r.kind.rawValue, r.pattern, i])
            }
        }
    }

    // MARK: snapshots

    public func snapshot(under folder: String) throws -> [String: SnapshotEntry] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM snapshot WHERE path LIKE ? ESCAPE '\\'",
                                        arguments: [Self.likePrefix(folder + "/")])
            var out: [String: SnapshotEntry] = [:]
            for r in rows {
                let e = SnapshotEntry(path: r["path"], inode: r["inode"], size: r["size"], mtime: r["mtime"])
                out[e.path] = e
            }
            return out
        }
    }

    public func record(snapshot entries: [SnapshotEntry], removing removed: [String]) throws {
        try queue.write { db in
            for p in removed { try db.execute(sql: "DELETE FROM snapshot WHERE path = ?", arguments: [p]) }
            for e in entries {
                try db.execute(sql: """
                    INSERT INTO snapshot(path, inode, size, mtime) VALUES (?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET inode = excluded.inode, size = excluded.size, mtime = excluded.mtime
                    """, arguments: [e.path, e.inode, e.size, e.mtime])
            }
        }
    }

    static func likePrefix(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    // MARK: runs and history

    public func begin(run: RunRecord) throws -> Int64 {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO run(started_at, trigger) VALUES (?, ?)",
                           arguments: [run.startedAt.timeIntervalSince1970, run.trigger])
            return db.lastInsertedRowID
        }
    }

    public func finish(run: RunRecord) throws {
        guard let id = run.id else { return }
        try queue.write { db in
            try db.execute(sql: """
                UPDATE run SET finished_at = ?, candidates = ?, moved = ?, pending = ?, refused = ?, error = ? WHERE id = ?
                """, arguments: [(run.finishedAt ?? Date()).timeIntervalSince1970, run.candidates, run.moved,
                                 run.pending, run.refused, run.error, id])
        }
    }

    public func add(history e: HistoryEntry) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO move_history(run_id, at, file_name, source_path, dest_path, folder_path, reason, confidence,
                                         status, detail, dest_inode, latency_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [e.runID, e.at.timeIntervalSince1970, e.fileName, e.sourcePath, e.destinationPath,
                                 e.folderPath, e.reason, e.confidence, e.status.rawValue, e.detail,
                                 e.destinationInode, e.latencyMs])
        }
    }

    public func entry(id: Int64) throws -> HistoryEntry? {
        try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM move_history WHERE id = ?", arguments: [id]).map(Self.history(row:)) }
    }

    public func movedEntries(run: Int64) throws -> [HistoryEntry] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM move_history WHERE run_id = ? AND status = 'moved' AND undone_at IS NULL ORDER BY id DESC",
                             arguments: [run]).map(Self.history(row:))
        }
    }

    /// Moves in the last `days` that haven't been undone or already seen as corrected.
    public func recentMoves(days: Int = 30) throws -> [HistoryEntry] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM move_history WHERE status = 'moved' AND undone_at IS NULL AND corrected_to IS NULL
                AND dest_inode IS NOT NULL AND at >= ?
                """, arguments: [since]).map(Self.history(row:))
        }
    }

    public func markUndone(_ id: Int64) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE move_history SET undone_at = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, id])
        }
    }

    public func markCorrected(_ id: Int64, to folderPath: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE move_history SET corrected_to = ? WHERE id = ?", arguments: [folderPath, id])
        }
    }

    static func history(row r: Row) -> HistoryEntry {
        HistoryEntry(id: r["id"], runID: r["run_id"], at: Date(timeIntervalSince1970: r["at"]),
                     fileName: r["file_name"], sourcePath: r["source_path"], destinationPath: r["dest_path"],
                     folderPath: r["folder_path"], reason: r["reason"], confidence: r["confidence"],
                     status: HistoryEntry.Status(rawValue: r["status"]) ?? .refused, detail: r["detail"],
                     destinationInode: r["dest_inode"], latencyMs: r["latency_ms"],
                     undoneAt: (r["undone_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                     correctedTo: r["corrected_to"])
    }

    public func history(limit: Int = 500) throws -> [HistoryEntry] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM move_history ORDER BY at DESC, id DESC LIMIT ?", arguments: [limit]).map(Self.history(row:))
        }
    }

    public func lastRun() throws -> RunRecord? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM run WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1").map {
                RunRecord(id: $0["id"], startedAt: Date(timeIntervalSince1970: $0["started_at"]),
                          finishedAt: ($0["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                          trigger: $0["trigger"], candidates: $0["candidates"], moved: $0["moved"],
                          pending: $0["pending"], refused: $0["refused"], error: $0["error"])
            }
        }
    }

    public func movedCount(since: Date) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE status = 'moved' AND at >= ?",
                             arguments: [since.timeIntervalSince1970]) ?? 0
        }
    }

    // MARK: review queue

    public func setPending(path: String, runID: Int64, suggestions: [(folderPath: String, p: Double)], reason: String) throws {
        let json = try String(decoding: JSONSerialization.data(withJSONObject: suggestions.map { ["folder": $0.folderPath, "p": $0.p] }), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_review(path, run_id, at, suggestions, reason) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET run_id = excluded.run_id, at = excluded.at,
                    suggestions = excluded.suggestions, reason = excluded.reason
                """, arguments: [path, runID, Date().timeIntervalSince1970, json, reason])
        }
    }

    public func clearPending(path: String) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM pending_review WHERE path = ?", arguments: [path]) }
    }

    public func pendingCount() throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_review") ?? 0 }
    }

    public func pendingPaths() throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT path FROM pending_review ORDER BY at DESC") }
    }

    public func pendingItems() throws -> [PendingItem] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_review ORDER BY at DESC").map { r in
                let raw = (r["suggestions"] as String).data(using: .utf8) ?? Data()
                let list = (try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]) ?? []
                return PendingItem(path: r["path"], at: Date(timeIntervalSince1970: r["at"]), reason: r["reason"],
                                   suggestions: list.compactMap { d in
                                       guard let f = d["folder"] as? String, let p = d["p"] as? Double else { return nil }
                                       return .init(folderPath: f, p: p)
                                   })
            }
        }
    }

    // MARK: learning

    /// Insert or replace an example (same key = same file/event).
    public func add(example e: TrainingExample) throws {
        let state = try String(decoding: JSONEncoder().encode(e.state), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO training_example(at, key, state, folder_id, source) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET at = excluded.at, state = excluded.state,
                    folder_id = excluded.folder_id, source = excluded.source
                """, arguments: [Date().timeIntervalSince1970, e.key, state, e.folderID, e.source])
        }
    }

    public func examples() throws -> [TrainingExample] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM training_example ORDER BY id").compactMap { r in
                guard let data = (r["state"] as String).data(using: .utf8),
                      let state = try? JSONDecoder().decode(FileState.self, from: data) else { return nil }
                return TrainingExample(key: r["key"], state: state, folderID: r["folder_id"], source: r["source"])
            }
        }
    }

    public func exampleCounts() throws -> [String: Int] {
        try queue.read { db in
            var out: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT source, COUNT(*) AS n FROM training_example GROUP BY source") {
                out[r["source"]] = r["n"]
            }
            return out
        }
    }

    public func value(_ key: String) throws -> String? {
        try queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    public func set(_ key: String, _ value: String?) throws {
        try queue.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: stats

    public func stats(now: Date = Date()) throws -> SortStats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now).timeIntervalSince1970
        let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970
        return try queue.read { db in
            var s = SortStats()
            let moved = "status = 'moved' AND undone_at IS NULL"
            s.movedAllTime = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE \(moved)") ?? 0
            s.movedThisWeek = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE \(moved) AND at >= ?", arguments: [week]) ?? 0
            s.movedToday = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE \(moved) AND at >= ?", arguments: [today]) ?? 0
            s.pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_review") ?? 0
            s.refused = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE status = 'refused'") ?? 0
            s.undone = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_history WHERE undone_at IS NOT NULL") ?? 0
            s.corrections = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_example WHERE source != 'bootstrap'") ?? 0
            s.runs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run WHERE finished_at IS NOT NULL") ?? 0
            for r in try Row.fetchAll(db, sql: "SELECT reason, COUNT(*) AS n FROM move_history WHERE \(moved) GROUP BY reason") {
                s.byReason[r["reason"]] = r["n"]
            }
            s.byFolder = try Row.fetchAll(db, sql: """
                SELECT folder_path, COUNT(*) AS n FROM move_history WHERE \(moved) AND folder_path IS NOT NULL
                GROUP BY folder_path ORDER BY n DESC LIMIT 10
                """).map { ($0["folder_path"], $0["n"]) }
            s.byDay = try Row.fetchAll(db, sql: """
                SELECT CAST((at - ?) / 86400 AS INTEGER) AS d, COUNT(*) AS n FROM move_history
                WHERE \(moved) AND at >= ? GROUP BY d ORDER BY d
                """, arguments: [week, week]).map { (Date(timeIntervalSince1970: week + Double($0["d"] as Int) * 86400), $0["n"]) }
            s.averageConfidence = try Double.fetchOne(db, sql: "SELECT AVG(confidence) FROM move_history WHERE \(moved) AND reason = 'model'")
            s.averageLatencyMs = try Double.fetchOne(db, sql: "SELECT AVG(latency_ms) FROM move_history WHERE latency_ms IS NOT NULL")
            return s
        }
    }
}
