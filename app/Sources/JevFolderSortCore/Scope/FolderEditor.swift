import Foundation

/// User-initiated folder creation from the Structure editor. The sorter itself
/// never creates folders; this only runs when the user clicks "New folder".
/// It can only create one new, empty directory directly inside the root or
/// inside an existing folder of the scope, and it never deletes or renames.
public enum FolderEditor {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noRoot, badName(String), parentMissing, exists, outsideRoot, protected(String), failed(String)

        public var description: String {
            switch self {
            case .noRoot: "choose a destination root first"
            case .badName(let n): "“\(n)” isn't a valid folder name"
            case .parentMissing: "the parent folder doesn't exist"
            case .exists: "a folder with that name already exists"
            case .outsideRoot: "folders can only be created inside the destination root"
            case .protected(let r): r
            case .failed(let e): "couldn't create the folder: \(e)"
            }
        }
    }

    public static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == name && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":") && name.utf8.count <= 255
    }

    /// Create `name` inside `parent` (relative path, nil = the root). Returns the new relative path.
    public static func createFolder(named name: String, in parent: String?, config: ScopeConfig,
                                    policy: ScopePolicy) -> Result<String, Failure> {
        guard let root = config.root, let croot = ScopePaths.canonical(root) else { return .failure(.noRoot) }
        guard validName(name) else { return .failure(.badName(name)) }
        var parentPath = croot
        if let parent {
            guard let folder = config.folders.first(where: { $0.relativePath == parent }),
                  let resolved = config.resolve(folder) else { return .failure(.parentMissing) }
            parentPath = resolved
        }
        guard let cparent = ScopePaths.canonical(parentPath), ScopePaths.isDirectory(cparent) else {
            return .failure(.parentMissing)
        }
        guard ScopePaths.isSameOrInside(cparent, croot) else { return .failure(.outsideRoot) }
        let target = cparent + "/" + name
        if let r = policy.refusal(for: target) { return .failure(.protected(r)) }
        if mkdir(target, 0o755) != 0 {
            return .failure(errno == EEXIST ? .exists : .failed(String(cString: strerror(errno))))
        }
        return .success(String(target.dropFirst(croot.count + 1)))
    }
}
