import Darwin
import Foundation
import UniformTypeIdentifiers

/// Deterministic per-folder rules, evaluated before the model. A match sends
/// the file to that folder with confidence 1.0 — still through ScopeGuard.
public struct RuleEngine: Sendable {
    public let rules: [Rule]
    private let depth: [String: Int]

    /// Only rules whose folder is currently allowed take part.
    public init(rules: [Rule], scope: ScopeConfig) {
        let allowed = Dictionary(uniqueKeysWithValues: scope.allowedFolders.map { ($0.id, $0) })
        self.rules = rules.filter { allowed[$0.folderID] != nil && !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
        depth = allowed.mapValues { $0.relativePath.split(separator: "/").count }
    }

    /// The winning folder id, or nil. Deepest folder wins; ties go to rule order.
    public func match(_ state: FileState) -> (folderID: String, rule: Rule)? {
        var best: (folderID: String, rule: Rule, depth: Int)?
        for rule in rules where Self.matches(rule, state) {
            let d = depth[rule.folderID] ?? 0
            if best == nil || d > best!.depth { best = (rule.folderID, rule, d) }
        }
        return best.map { ($0.folderID, $0.rule) }
    }

    public static func matches(_ rule: Rule, _ state: FileState) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
        switch rule.kind {
        case .fileExtension:
            let wanted = pattern.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased() }
            return wanted.contains(state.ext.lowercased())
        case .nameGlob:
            return fnmatch(pattern, state.name, FNM_CASEFOLD) == 0
        case .sourceDomain:
            let domain = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return (state.whereFrom ?? []).contains { url in
                guard let host = URL(string: url)?.host?.lowercased() else { return false }
                return host == domain || host.hasSuffix("." + domain)
            }
        case .contentType:
            guard let id = state.contentType, let have = UTType(id), let want = UTType(pattern) else { return false }
            return have.conforms(to: want)
        }
    }
}
