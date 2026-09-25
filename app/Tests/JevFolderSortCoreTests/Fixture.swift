import Foundation
@testable import JevFolderSortCore

/// A throwaway "home" with a watched Inbox, a Sorted root and an Outside
/// folder the app must never touch.
final class Fixture {
    let home: String
    var inbox: String { home + "/Inbox" }
    var root: String { home + "/Sorted" }
    var outside: String { home + "/Outside" }
    let policy: ScopePolicy
    var scope: ScopeConfig

    init(folders: [String] = ["Finance", "Finance/Taxes", "Photos", "Code"]) throws {
        let base = NSTemporaryDirectory() + "jevsort-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        home = ScopePaths.canonical(base)!
        policy = ScopePolicy(home: home, deniedPrefixes: [home + "/Library"])
        for dir in ["Inbox", "Sorted", "Outside", "Library"] + folders.map({ "Sorted/" + $0 }) {
            try FileManager.default.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true)
        }
        scope = ScopeConfig(
            sources: [home + "/Inbox"], root: home + "/Sorted",
            folders: folders.enumerated().map { DestinationFolder(id: "f\($0.offset + 1)", relativePath: $0.element) })
    }

    deinit { try? FileManager.default.removeItem(atPath: home) }

    var guardrail: ScopeGuard { ScopeGuard(config: scope, policy: policy) }

    @discardableResult
    func file(_ path: String, _ contents: String? = nil) throws -> String {
        let full = path.hasPrefix("/") ? path : home + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (contents ?? UUID().uuidString).write(toFile: full, atomically: false, encoding: .utf8)
        return full
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path.hasPrefix("/") ? path : home + "/" + path)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: path.hasPrefix("/") ? path : home + "/" + path, encoding: .utf8)
    }

    /// Every regular file under home, relative path -> contents.
    func allFiles() -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(atPath: home)
        while let rel = e?.nextObject() as? String {
            let full = home + "/" + rel
            if Scanner.entry(full) != nil { out[rel] = read(full) }
        }
        return out
    }
}
