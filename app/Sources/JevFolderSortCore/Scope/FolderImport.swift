import Foundation

public enum FolderImport {
    /// Read the sub-folder tree under `root` (canonical), up to `maxDepth`
    /// levels. Skips hidden folders, packages (.app, .photoslibrary, …) and
    /// symlinks. Existing folders keep their id, description and allowed flag;
    /// new ones get fresh ids and start allowed.
    public static func folders(under root: String, merging existing: [DestinationFolder], maxDepth: Int = 4) -> [DestinationFolder] {
        var found: [String] = []
        func walk(_ dir: String, _ rel: String, _ depth: Int) {
            guard depth <= maxDepth else { return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            for name in names where !name.hasPrefix(".") {
                let path = dir + "/" + name
                guard ScopePaths.isDirectory(path), !ScopePaths.isPackage(path) else { continue }
                let relPath = rel.isEmpty ? name : rel + "/" + name
                found.append(relPath)
                walk(path, relPath, depth + 1)
            }
        }
        walk(root, "", 1)

        let byPath = Dictionary(existing.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        var nextID = (existing.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        return found.map { rel in
            if let f = byPath[rel] { return f }
            defer { nextID += 1 }
            return DestinationFolder(id: "f\(nextID)", relativePath: rel)
        }
    }
}
