import Foundation

/// Why a move was refused. Every refusal is logged to history.
public enum ScopeViolation: Error, Equatable, Sendable, CustomStringConvertible {
    case scopeInvalid([String])
    case unknownFolder(String)
    case folderNotAllowed(String)
    case sourceMissing
    case sourceNotRegularFile
    case sourceIsAliasOrHidden
    case sourceOutsideWatchedFolders
    case destinationMissing
    case destinationOutsideRoot
    case destinationProtected(String)
    case destinationChanged
    case crossVolume
    case alreadyInDestination
    case moveFailed(String)

    public var description: String {
        switch self {
        case .scopeInvalid(let issues): "scope is not valid: \(issues.joined(separator: "; "))"
        case .unknownFolder(let id): "unknown folder id \(id)"
        case .folderNotAllowed(let p): "folder \(p) is not an allowed destination"
        case .sourceMissing: "file no longer exists"
        case .sourceNotRegularFile: "not a regular file (folder, package, symlink or special file)"
        case .sourceIsAliasOrHidden: "hidden file or Finder alias"
        case .sourceOutsideWatchedFolders: "file is not directly inside a watched folder"
        case .destinationMissing: "destination folder no longer exists (folders are never created)"
        case .destinationOutsideRoot: "destination is outside the destination root"
        case .destinationProtected(let r): "destination is protected: \(r)"
        case .destinationChanged: "destination folder was replaced by a symlink or moved"
        case .crossVolume: "source and destination are on different volumes"
        case .alreadyInDestination: "file is already in that folder"
        case .moveFailed(let e): "move failed: \(e)"
        }
    }
}

/// Proof that a specific move was checked against the scope. Only `ScopeGuard`
/// can create one (fileprivate init), and only `ScopeGuard.move` consumes one.
public struct ValidatedMove: Equatable, Sendable {
    public let sourcePath: String
    public let folder: DestinationFolder
    public let destinationDirectory: String
    fileprivate let device: dev_t
    fileprivate let inode: ino_t

    fileprivate init(sourcePath: String, folder: DestinationFolder, destinationDirectory: String, device: dev_t, inode: ino_t) {
        self.sourcePath = sourcePath
        self.folder = folder
        self.destinationDirectory = destinationDirectory
        self.device = device
        self.inode = inode
    }
}

public struct MoveOutcome: Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let folderID: String
}

/// The single chokepoint for moving files. Nothing else in the codebase calls
/// rename/moveItem (a test enforces this). Every check is repeated right
/// before the rename, and the rename itself refuses to overwrite.
public struct ScopeGuard: Sendable {
    public let config: ScopeConfig
    public let policy: ScopePolicy

    public init(config: ScopeConfig, policy: ScopePolicy = .system) {
        self.config = config
        self.policy = policy
    }

    /// Check a proposed move of `sourcePath` into the folder with `folderID`.
    /// `folderID` is whatever the engine or a rule answered; it is only ever
    /// looked up in the user's allowlist, never interpreted as a path.
    public func validate(sourcePath: String, folderID: String) -> Result<ValidatedMove, ScopeViolation> {
        let issues = config.issues(policy: policy)
        guard issues.isEmpty else { return .failure(.scopeInvalid(issues.map(\.message))) }
        guard let root = config.root else { return .failure(.scopeInvalid(["no root"])) }

        guard let folder = config.folders.first(where: { $0.id == folderID }) else {
            return .failure(.unknownFolder(folderID))
        }
        guard folder.allowed else { return .failure(.folderNotAllowed(folder.relativePath)) }

        // --- source: a regular, visible, non-alias file directly inside a watched folder
        let name = (sourcePath as NSString).lastPathComponent
        let parent = (sourcePath as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(sourcePath, &st) == 0 else { return .failure(.sourceMissing) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.sourceNotRegularFile) }
        guard !name.hasPrefix("."), !name.isEmpty, !name.contains("/"), !isAlias(sourcePath) else {
            return .failure(.sourceIsAliasOrHidden)
        }
        let watched = config.sources.compactMap(ScopePaths.canonical)
        guard let cparent = ScopePaths.canonical(parent), watched.contains(cparent) else {
            return .failure(.sourceOutsideWatchedFolders)
        }

        // --- destination: an existing, allowed folder strictly inside the root
        guard let dest = config.resolve(folder) else { return .failure(.destinationOutsideRoot) }
        guard let cdest = ScopePaths.canonical(dest) else { return .failure(.destinationMissing) }
        guard cdest == dest else { return .failure(.destinationChanged) }
        guard ScopePaths.isDirectory(cdest), !ScopePaths.isPackage(cdest) else { return .failure(.destinationMissing) }
        guard ScopePaths.isStrictlyInside(cdest, root) else { return .failure(.destinationOutsideRoot) }
        if let r = policy.refusal(for: cdest) { return .failure(.destinationProtected(r)) }
        guard cdest != cparent else { return .failure(.alreadyInDestination) }

        var dst = stat()
        guard stat(cdest, &dst) == 0 else { return .failure(.destinationMissing) }
        guard dst.st_dev == st.st_dev else { return .failure(.crossVolume) }

        return .success(ValidatedMove(
            sourcePath: cparent + "/" + name, folder: folder, destinationDirectory: cdest,
            device: st.st_dev, inode: st.st_ino))
    }

    /// Validate and move in one step. The file keeps its name unless one
    /// already exists at the destination, in which case it becomes
    /// `name 2.ext`, `name 3.ext`, … (Finder style). Never overwrites.
    public func move(sourcePath: String, folderID: String) -> Result<MoveOutcome, ScopeViolation> {
        switch validate(sourcePath: sourcePath, folderID: folderID) {
        case .failure(let v): return .failure(v)
        case .success(let m): return perform(m)
        }
    }

    private func perform(_ m: ValidatedMove) -> Result<MoveOutcome, ScopeViolation> {
        // Re-check at the last moment: same file (device + inode) still at the path.
        var st = stat()
        guard lstat(m.sourcePath, &st) == 0, st.st_dev == m.device, st.st_ino == m.inode,
              (st.st_mode & S_IFMT) == S_IFREG
        else { return .failure(.sourceMissing) }

        let name = (m.sourcePath as NSString).lastPathComponent
        for candidate in Self.candidateNames(for: name) {
            let target = m.destinationDirectory + "/" + candidate
            // RENAME_EXCL: atomic, and fails with EEXIST instead of overwriting.
            if renamex_np(m.sourcePath, target, UInt32(RENAME_EXCL)) == 0 {
                return .success(MoveOutcome(sourcePath: m.sourcePath, destinationPath: target, folderID: m.folder.id))
            }
            let err = errno
            if err == EEXIST { continue }
            return .failure(.moveFailed(String(cString: strerror(err))))
        }
        return .failure(.moveFailed("too many files with the same name"))
    }

    /// `report.pdf`, `report 2.pdf`, `report 3.pdf`, … up to 999.
    public static func candidateNames(for name: String) -> [String] {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        return [name] + (2...999).map { ext.isEmpty ? "\(stem) \($0)" : "\(stem) \($0).\(ext)" }
    }

    private func isAlias(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return (values?.isAliasFile ?? false) || (values?.isSymbolicLink ?? false)
    }
}
