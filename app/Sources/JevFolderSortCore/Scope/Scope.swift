import Foundation

/// What the app is allowed to touch. This is the user's definition from the
/// Scope settings pane, and the *only* input `ScopeGuard` trusts.
///
/// - `sources`: files are only ever taken from directly inside these folders.
/// - `root`: every destination must be strictly inside this folder.
/// - `folders`: the destination folders under `root`; only `allowed` ones can
///   receive files. Folders are never created by the app.
public struct ScopeConfig: Equatable, Sendable {
    public var sources: [String]
    public var root: String?
    public var folders: [DestinationFolder]

    public init(sources: [String] = [], root: String? = nil, folders: [DestinationFolder] = []) {
        self.sources = sources
        self.root = root
        self.folders = folders
    }

    public var allowedFolders: [DestinationFolder] { folders.filter(\.allowed) }
}

public struct DestinationFolder: Equatable, Hashable, Sendable, Identifiable {
    /// Stable opaque id (`f1`, `f2`, …). The engine only ever sees this id.
    public var id: String
    /// Path relative to the scope root, e.g. `Finance/Taxes`.
    public var relativePath: String
    public var description: String
    public var allowed: Bool

    public init(id: String, relativePath: String, description: String = "", allowed: Bool = true) {
        self.id = id
        self.relativePath = relativePath
        self.description = description
        self.allowed = allowed
    }
}

/// Paths that can never be a source, a root or a destination, and the rule
/// that everything must live strictly inside the user's home folder or on an
/// external volume. Injected so tests can point "home" at a temp directory.
public struct ScopePolicy: Sendable {
    public var home: String
    public var deniedPrefixes: [String]
    public var volumesRoot: String

    public init(home: String, deniedPrefixes: [String], volumesRoot: String = "/Volumes") {
        self.home = ScopePaths.canonical(home) ?? home
        self.deniedPrefixes = deniedPrefixes.map { ScopePaths.canonical($0) ?? $0 }
        self.volumesRoot = volumesRoot
    }

    /// The real policy the app runs with.
    public static var system: ScopePolicy {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ScopePolicy(home: home, deniedPrefixes: [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/opt", "/etc", "/var",
            "/cores", "/dev",
            // ~/Library holds app data, iCloud Drive (Mobile Documents) and
            // CloudStorage (Dropbox, Google Drive, OneDrive). Never touched.
            home + "/Library",
            home + "/.Trash",
            home + "/Applications",
        ] + (Bundle.main.bundlePath.hasSuffix(".app") ? [Bundle.main.bundlePath] : []))
    }

    /// Why `path` (canonical) may not be used as a scope folder, or nil if it may.
    public func refusal(for path: String) -> String? {
        if let denied = deniedPrefixes.first(where: { ScopePaths.isSameOrInside(path, $0) }) {
            return "\(path) is inside a protected location (\(denied))"
        }
        if ScopePaths.isStrictlyInside(path, home) { return nil }
        let volumeParts = path.split(separator: "/")
        if ScopePaths.isStrictlyInside(path, volumesRoot), volumeParts.count >= 3 { return nil }
        if path == home { return "Your whole home folder is too broad; pick a folder inside it" }
        return "\(path) is outside your home folder and external volumes"
    }
}

public enum ScopePaths {
    /// Resolve symlinks, `.` and `..` (realpath). Nil if the path doesn't exist.
    public static func canonical(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func isStrictlyInside(_ path: String, _ ancestor: String) -> Bool {
        let base = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(base) && path.count > base.count
    }

    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || isStrictlyInside(path, ancestor)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func isPackage(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }
}

/// A problem with the scope configuration itself, shown in the Scope pane.
/// While any issue exists, nothing is moved at all.
public struct ScopeIssue: Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

extension ScopeConfig {
    /// Every reason this configuration is unsafe or unusable. Empty = OK.
    public func issues(policy: ScopePolicy) -> [ScopeIssue] {
        var out: [ScopeIssue] = []
        func issue(_ m: String) { out.append(ScopeIssue(message: m)) }

        if sources.isEmpty { issue("Add at least one folder to watch") }
        var canonicalSources: [String] = []
        for s in sources {
            guard let c = ScopePaths.canonical(s), ScopePaths.isDirectory(c) else {
                issue("Watched folder \(s) doesn't exist"); continue
            }
            if let r = policy.refusal(for: c) { issue("Watched folder: \(r)") }
            canonicalSources.append(c)
        }
        if Set(canonicalSources).count != canonicalSources.count { issue("A watched folder is listed twice") }

        guard let root else { issue("Choose a destination root folder"); return out }
        guard let croot = ScopePaths.canonical(root), ScopePaths.isDirectory(croot) else {
            issue("Destination root \(root) doesn't exist"); return out
        }
        if let r = policy.refusal(for: croot) { issue("Destination root: \(r)") }
        if croot != root { issue("Destination root must not be a symlink or contain one") }

        if allowedFolders.isEmpty { issue("Allow at least one destination folder") }
        if Set(folders.map(\.id)).count != folders.count { issue("Duplicate folder ids") }
        for f in allowedFolders {
            guard let path = resolve(f) else { issue("Folder “\(f.relativePath)” is not a valid path"); continue }
            guard let c = ScopePaths.canonical(path), ScopePaths.isDirectory(c) else {
                issue("Folder “\(f.relativePath)” no longer exists"); continue
            }
            if c != path { issue("Folder “\(f.relativePath)” is a symlink") }
            if ScopePaths.isPackage(c) { issue("“\(f.relativePath)” is a package, not a folder") }
            if canonicalSources.contains(c) { issue("“\(f.relativePath)” is also a watched folder") }
        }
        return out
    }

    /// Absolute path of a destination folder, or nil if the relative path
    /// could escape the root (absolute, `..`, empty components).
    public func resolve(_ folder: DestinationFolder) -> String? {
        guard let root else { return nil }
        let parts = folder.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !folder.relativePath.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return root + "/" + folder.relativePath
    }

    /// A one-paragraph plain-English description for the Scope pane.
    public func summary() -> String {
        let from = sources.isEmpty ? "(no folders yet)" : sources.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        let to = allowedFolders.map(\.relativePath).sorted()
        let rootName = root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "(no root chosen)"
        return """
        jev-folder-sort only takes files sitting directly inside: \(from).
        It only moves them into these \(to.count) folders inside \(rootName): \(to.isEmpty ? "(none allowed yet)" : to.joined(separator: ", ")).
        It never creates, renames or deletes folders, never touches sub-folders of watched folders, and never moves anything anywhere else.
        """
    }
}
