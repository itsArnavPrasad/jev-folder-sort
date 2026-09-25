import Foundation

/// Finds new or changed files at the top level of the watched folders by
/// diffing (inode, size, mtime) against the last snapshot.
public struct Scanner: Sendable {
    /// Browsers and download tools write to these until the download finishes.
    static let inProgressExtensions: Set<String> = ["crdownload", "part", "download", "tmp", "partial", "opdownload"]

    public var stabilityDelay: Duration

    public init(stabilityDelay: Duration = .seconds(2)) {
        self.stabilityDelay = stabilityDelay
    }

    public struct Result: Sendable {
        /// New or changed, stable files to decide on.
        public var candidates: [SnapshotEntry] = []
        /// Files that vanished since the last scan (drop from the snapshot).
        public var removed: [String] = []
        /// Files still being written; retried on the next scan.
        public var deferred: [String] = []
    }

    public func scan(sources: [String], snapshot: (String) throws -> [String: SnapshotEntry]) async throws -> Result {
        var result = Result()
        var fresh: [SnapshotEntry] = []
        for source in sources {
            guard let folder = ScopePaths.canonical(source), ScopePaths.isDirectory(folder) else { continue }
            let previous = try snapshot(folder)
            var seen = Set<String>()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                guard !name.hasPrefix("."),
                      !Self.inProgressExtensions.contains((name as NSString).pathExtension.lowercased())
                else { continue }
                let path = folder + "/" + name
                guard let entry = Self.entry(path) else { continue }  // not a regular file
                seen.insert(path)
                if previous[path] != entry { fresh.append(entry) }
            }
            result.removed += previous.keys.filter { !seen.contains($0) }
        }
        guard !fresh.isEmpty else { return result }

        // A file whose size or mtime moves during the delay is still being written.
        try await Task.sleep(for: stabilityDelay)
        for entry in fresh {
            if Self.entry(entry.path) == entry {
                result.candidates.append(entry)
            } else {
                result.deferred.append(entry.path)
            }
        }
        return result
    }

    /// Snapshot entry for a regular file (not a symlink, folder or package).
    static func entry(_ path: String) -> SnapshotEntry? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return SnapshotEntry(path: path, inode: Int64(st.st_ino), size: Int64(st.st_size), mtime: mtime)
    }
}
