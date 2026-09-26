import Foundation
import Testing
@testable import JevFolderSortCore

@Suite("ScopeGuard — nothing moves outside the user's scope")
struct ScopeGuardTests {
    @Test func movesAllowedFileIntoAllowedFolder() throws {
        let fx = try Fixture()
        let src = try fx.file("Inbox/w2.pdf", "tax")
        let outcome = try fx.guardrail.move(sourcePath: src, folderID: "f2").get()
        #expect(outcome.destinationPath == fx.root + "/Finance/Taxes/w2.pdf")
        #expect(fx.read(outcome.destinationPath) == "tax")
        #expect(!fx.exists(src))
    }

    @Test func validConfigHasNoIssuesAndSummaryNamesFolders() throws {
        let fx = try Fixture()
        #expect(fx.scope.issues(policy: fx.policy).isEmpty)
        let summary = fx.scope.summary()
        #expect(summary.contains("Finance/Taxes") && summary.contains("Inbox"))
    }

    @Test func unknownFolderIDIsRefused() throws {
        let fx = try Fixture()
        let src = try fx.file("Inbox/a.txt")
        for bogus in ["f99", "", "__none__", "../Outside", fx.outside, "Finance"] {
            #expect(throws: ScopeViolation.unknownFolder(bogus)) { try fx.guardrail.move(sourcePath: src, folderID: bogus).get() }
        }
        #expect(fx.exists(src))
    }

    @Test func uncheckedFolderIsRefused() throws {
        let fx = try Fixture()
        fx.scope.folders[2].allowed = false
        let src = try fx.file("Inbox/p.jpg")
        #expect(throws: ScopeViolation.folderNotAllowed("Photos")) { try fx.guardrail.move(sourcePath: src, folderID: "f3").get() }
        #expect(fx.exists(src))
    }

    @Test func nestedAndTraversalSourcesAreRefused() throws {
        let fx = try Fixture()
        let nested = try fx.file("Inbox/sub/deep.txt")
        let outsider = try fx.file("Outside/secret.txt")
        #expect(throws: ScopeViolation.sourceOutsideWatchedFolders) { try fx.guardrail.move(sourcePath: nested, folderID: "f1").get() }
        #expect(throws: ScopeViolation.sourceOutsideWatchedFolders) { try fx.guardrail.move(sourcePath: outsider, folderID: "f1").get() }
        #expect(throws: ScopeViolation.sourceOutsideWatchedFolders) {
            try fx.guardrail.move(sourcePath: fx.inbox + "/../Outside/secret.txt", folderID: "f1").get()
        }
        #expect(fx.exists(nested) && fx.exists(outsider))
    }

    @Test func symlinkedSourceFolderPathStillResolvesToRealParent() throws {
        let fx = try Fixture()
        try FileManager.default.createSymbolicLink(atPath: fx.home + "/InboxLink", withDestinationPath: fx.outside)
        let secret = try fx.file("Outside/secret.txt")
        // Reaching Outside through a symlink doesn't make it a watched folder.
        #expect(throws: ScopeViolation.sourceOutsideWatchedFolders) {
            try fx.guardrail.move(sourcePath: fx.home + "/InboxLink/secret.txt", folderID: "f1").get()
        }
        #expect(fx.exists(secret))
    }

    @Test func symlinkDirectoryAndHiddenSourcesAreRefused() throws {
        let fx = try Fixture()
        let target = try fx.file("Outside/real.txt")
        try FileManager.default.createSymbolicLink(atPath: fx.inbox + "/link.txt", withDestinationPath: target)
        try FileManager.default.createDirectory(atPath: fx.inbox + "/Folder", withIntermediateDirectories: true)
        let hidden = try fx.file("Inbox/.secret")
        #expect(throws: ScopeViolation.sourceNotRegularFile) { try fx.guardrail.move(sourcePath: fx.inbox + "/link.txt", folderID: "f1").get() }
        #expect(throws: ScopeViolation.sourceNotRegularFile) { try fx.guardrail.move(sourcePath: fx.inbox + "/Folder", folderID: "f1").get() }
        #expect(throws: ScopeViolation.sourceIsAliasOrHidden) { try fx.guardrail.move(sourcePath: hidden, folderID: "f1").get() }
        #expect(throws: ScopeViolation.sourceMissing) { try fx.guardrail.move(sourcePath: fx.inbox + "/nope.txt", folderID: "f1").get() }
        #expect(fx.exists(target) && fx.exists(fx.inbox + "/Folder"))
    }

    @Test func folderPathsThatEscapeTheRootMakeTheScopeInvalid() throws {
        for bad in ["../Outside", "/etc", "Finance/../../Outside", "", "Finance//Taxes", "./Photos"] {
            let fx = try Fixture()
            fx.scope.folders.append(DestinationFolder(id: "bad", relativePath: bad))
            let src = try fx.file("Inbox/a.txt")
            #expect(!fx.scope.issues(policy: fx.policy).isEmpty, "\(bad)")
            let result = fx.guardrail.move(sourcePath: src, folderID: "bad")
            guard case .failure(.scopeInvalid) = result else { Issue.record("\(bad) not refused: \(result)"); continue }
            #expect(fx.exists(src))
        }
    }

    @Test func destinationSwappedForSymlinkIsRefused() throws {
        let fx = try Fixture()
        let src = try fx.file("Inbox/a.txt")
        // After the user set up the scope, "Photos" is replaced by a link to Outside.
        try FileManager.default.removeItem(atPath: fx.root + "/Photos")
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/Photos", withDestinationPath: fx.outside)
        let result = fx.guardrail.move(sourcePath: src, folderID: "f3")
        guard case .failure = result else { Issue.record("moved through symlink"); return }
        #expect(fx.exists(src))
        #expect(!fx.exists("Outside/a.txt"))
    }

    @Test func deletedDestinationIsNeverRecreated() throws {
        let fx = try Fixture()
        let src = try fx.file("Inbox/a.txt")
        try FileManager.default.removeItem(atPath: fx.root + "/Code")
        let result = fx.guardrail.move(sourcePath: src, folderID: "f4")
        guard case .failure(.scopeInvalid) = result else { Issue.record("expected refusal, got \(result)"); return }
        #expect(!fx.exists(fx.root + "/Code"))
        #expect(fx.exists(src))
    }

    @Test func destinationThatIsAFileIsRefused() throws {
        let fx = try Fixture()
        try fx.file("Sorted/NotAFolder")
        fx.scope.folders.append(DestinationFolder(id: "x", relativePath: "NotAFolder"))
        #expect(!fx.scope.issues(policy: fx.policy).isEmpty)
    }

    @Test func protectedAndTooBroadRootsAreRejected() throws {
        let fx = try Fixture()
        try FileManager.default.createDirectory(atPath: fx.home + "/Library/Mobile Documents", withIntermediateDirectories: true)
        for root in [fx.home, fx.home + "/Library/Mobile Documents", "/", "/Users", Fixture.fixtureRoot] {
            var s = fx.scope
            s.root = ScopePaths.canonical(root)
            #expect(!s.issues(policy: fx.policy).isEmpty, "\(root) accepted as root")
        }
        var s = fx.scope
        s.sources = [fx.home + "/Library"]
        #expect(!s.issues(policy: fx.policy).isEmpty)
        s.sources = [fx.inbox, fx.inbox]
        #expect(!s.issues(policy: fx.policy).isEmpty)
    }

    @Test func systemPolicyProtectsLibraryAndSystemPaths() {
        let p = ScopePolicy.system
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/", "/System/Library", "/Applications/Safari.app", "/private/tmp", home, home + "/Library/Mobile Documents/com~apple~CloudDocs"] {
            #expect(p.refusal(for: path) != nil, "\(path) allowed")
        }
        #expect(p.refusal(for: home + "/Downloads") == nil)
        #expect(p.refusal(for: "/Volumes/External/Sorted") == nil)
        #expect(p.refusal(for: "/Volumes/External") != nil)  // a whole volume is too broad
    }

    @Test func watchedFolderCannotAlsoBeADestination() throws {
        let fx = try Fixture()
        fx.scope.sources.append(fx.root + "/Photos")
        #expect(!fx.scope.issues(policy: fx.policy).isEmpty)
    }

    @Test func collisionsGetFinderStyleSuffixAndNeverOverwrite() throws {
        let fx = try Fixture()
        try fx.file("Sorted/Code/main.py", "original")
        try fx.file("Sorted/Code/main 2.py", "second")
        let src = try fx.file("Inbox/main.py", "new")
        let out = try fx.guardrail.move(sourcePath: src, folderID: "f4").get()
        #expect(out.destinationPath.hasSuffix("/Code/main 3.py"))
        #expect(fx.read("Sorted/Code/main.py") == "original")
        #expect(fx.read("Sorted/Code/main 2.py") == "second")
        #expect(ScopeGuard.candidateNames(for: "Makefile").prefix(2) == ["Makefile", "Makefile 2"])
    }

    @Test func invalidScopeBlocksEveryMove() throws {
        let fx = try Fixture()
        fx.scope.root = nil
        let src = try fx.file("Inbox/a.txt")
        guard case .failure(.scopeInvalid) = fx.guardrail.move(sourcePath: src, folderID: "f1") else {
            Issue.record("moved without a root"); return
        }
    }

    /// Random soup of files, decoys and folder ids (valid, unchecked, bogus).
    /// Afterwards every file must exist exactly once with its contents intact,
    /// nothing outside the Inbox may have moved, and every moved file must sit
    /// in an allowed folder.
    @Test(arguments: 0..<8) func randomizedMovesNeverLoseOrEscape(seed: Int) throws {
        var rng = SeededRandom(seed: UInt64(seed + 1))
        let fx = try Fixture()
        fx.scope.folders[Int.random(in: 0..<4, using: &rng)].allowed = false
        var decoys: [String: String] = [:]
        for i in 0..<10 {
            let rel = ["Outside/d\(i).txt", "Inbox/sub/d\(i).txt", "Sorted/Photos/d\(i).jpg"][i % 3]
            decoys[rel] = "decoy-\(i)"
            try fx.file(rel, "decoy-\(i)")
        }
        var inboxFiles: [String] = []
        for i in 0..<40 {
            let name = ["report.pdf", "img.jpg", "main.py", "notes \(i).txt", "a"][i % 5]
            let path = fx.inbox + "/" + (i < 5 ? name : "\(i)-" + name)
            try fx.file(path, "file-\(i)")
            inboxFiles.append(path)
        }
        let before = fx.allFiles()
        let ids = ["f1", "f2", "f3", "f4", "f9", "../Outside", "__none__", ""]
        for _ in 0..<80 {
            let src = inboxFiles.randomElement(using: &rng)!
            _ = fx.guardrail.move(sourcePath: src, folderID: ids.randomElement(using: &rng)!)
        }
        let after = fx.allFiles()
        #expect(before.values.sorted() == after.values.sorted(), "a file was lost or duplicated")
        for (rel, contents) in decoys { #expect(after[rel] == contents, "decoy \(rel) moved") }
        let allowed = fx.scope.allowedFolders.map { "Sorted/" + $0.relativePath + "/" }
        for (rel, contents) in after where contents.hasPrefix("file-") && !rel.hasPrefix("Inbox/") {
            #expect(allowed.contains { rel.hasPrefix($0) && !rel.dropFirst($0.count).contains("/") }, "\(rel) escaped")
        }
    }

    /// The guarantee only holds if ScopeGuard is the only code that moves or
    /// deletes files. Fail the build if anything else starts to.
    @Test func noOtherCodeMovesOrDeletesFiles() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let forbidden = ["moveItem", "renamex_np", "rename(", "renameat", "removeItem", "unlink(", "trashItem", "copyItem", "replaceItem"]
        var offenders: [String] = []
        let e = FileManager.default.enumerator(atPath: sources.path)
        while let rel = e?.nextObject() as? String {
            guard rel.hasSuffix(".swift"), !rel.hasSuffix("Scope/ScopeGuard.swift") else { continue }
            let text = try String(contentsOfFile: sources.path + "/" + rel, encoding: .utf8)
            for f in forbidden where text.contains(f) { offenders.append("\(rel): \(f)") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
