import Foundation
import Testing
@testable import JevFolderSortCore

/// Classifier double: answers from a table keyed by file name.
struct ScriptedClassifier: FolderClassifier {
    var answers: [String: (String, Double)]
    let seen = Recorder()

    final class Recorder: @unchecked Sendable {
        var trees: [[EngineFolder]] = []
        var files: [[EngineFile]] = []
    }

    func classify(tree: [EngineFolder], files: [EngineFile]) async throws -> [EngineDecision] {
        seen.trees.append(tree)
        seen.files.append(files)
        return files.map { f in
            let (choice, p) = answers[f.state.name] ?? (EngineDecision.noneID, 0.9)
            return EngineDecision(file: f.id, choice: choice, confidence: p,
                                  top: [.init(folder: choice, p: p)], latencyMs: 1)
        }
    }
}

extension EngineDecision {
    init(file: String, choice: String, confidence: Double, top: [Suggestion], latencyMs: Double) {
        let json = try! JSONSerialization.data(withJSONObject: [
            "file": file, "choice": choice, "confidence": confidence, "latency_ms": latencyMs,
            "top": top.map { ["folder": $0.folder, "p": $0.p] },
        ])
        self = try! JSONDecoder().decode(EngineDecision.self, from: json)
    }
}

extension EngineDecision.Suggestion {
    init(folder: String, p: Double) {
        self = try! JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: ["folder": folder, "p": p]))
    }
}

@Suite("Pipeline")
struct PipelineTests {
    func setup(_ fx: Fixture, answers: [String: (String, Double)], rules: [Rule] = []) throws -> (AppDatabase, Pipeline, ScriptedClassifier) {
        let db = try AppDatabase()
        try db.save(fx.scope)
        try db.save(rules: rules)
        let classifier = ScriptedClassifier(answers: answers)
        let pipeline = Pipeline(db: db, classifier: classifier, policy: fx.policy, scanner: Scanner(stabilityDelay: .milliseconds(10)))
        return (db, pipeline, classifier)
    }

    @Test func sortsConfidentFilesAndLeavesTheRest() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/w2.txt", "Form W-2 wages")
        try fx.file("Inbox/IMG_1.jpg")
        try fx.file("Inbox/unsure.txt")
        try fx.file("Inbox/nothing.bin")
        try fx.file("Inbox/evil.txt")
        try fx.file("Inbox/.hidden")
        try fx.file("Inbox/sub/nested.pdf")
        try fx.file("Outside/decoy.pdf")
        let (db, pipeline, classifier) = try setup(fx, answers: [
            "w2.txt": ("f2", 0.95), "IMG_1.jpg": ("f3", 0.8), "unsure.txt": ("f1", 0.4),
            "nothing.bin": ("__none__", 0.99), "evil.txt": ("../../Outside", 0.99),
        ])

        let run = try await pipeline.run(trigger: "test")
        #expect(run.error == nil)
        #expect(run.candidates == 5)  // hidden + nested never considered
        #expect(run.moved == 2 && run.pending == 3)
        #expect(fx.exists("Sorted/Finance/Taxes/w2.txt") && fx.exists("Sorted/Photos/IMG_1.jpg"))
        for stays in ["Inbox/unsure.txt", "Inbox/nothing.bin", "Inbox/evil.txt", "Inbox/.hidden", "Inbox/sub/nested.pdf", "Outside/decoy.pdf"] {
            #expect(fx.exists(stays), "\(stays) moved")
        }
        #expect(try db.pendingCount() == 3)

        // The engine saw folder ids and relative names only — never absolute paths.
        let tree = try #require(classifier.seen.trees.first)
        #expect(tree.map(\.id) == ["f1", "f2", "f3", "f4"])
        #expect(!tree.contains { $0.path.hasPrefix("/") || $0.path.contains(fx.home) })
        let text = try String(decoding: JSONEncoder().encode(classifier.seen.files.first!), as: UTF8.self)
        #expect(!text.contains(fx.home))
        #expect(text.contains("Form W-2 wages"))  // first N KB of text is included

        let history = try db.history()
        #expect(history.filter { $0.status == .moved }.count == 2)
        #expect(history.contains { $0.fileName == "unsure.txt" && $0.detail?.contains("below threshold") == true })

        // Second run: nothing changed, nothing re-asked.
        let again = try await pipeline.run(trigger: "test")
        #expect(again.candidates == 0 && classifier.seen.files.count == 1)
    }

    @Test func rulesWinOverTheModelButStillGoThroughTheGuard() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/script.py")
        try fx.file("Inbox/statement.pdf")
        let (_, pipeline, classifier) = try setup(fx, answers: ["script.py": ("f1", 0.99)], rules: [
            Rule(folderID: "f4", kind: .fileExtension, pattern: "py, sh"),
            Rule(folderID: "f1", kind: .nameGlob, pattern: "statement*"),
            Rule(folderID: "f2", kind: .nameGlob, pattern: "*.pdf"),  // deeper folder wins
        ])
        let run = try await pipeline.run(trigger: "test")
        #expect(run.moved == 2)
        #expect(fx.exists("Sorted/Code/script.py"))
        #expect(fx.exists("Sorted/Finance/Taxes/statement.pdf"))
        #expect(classifier.seen.files.isEmpty)  // model never asked
    }

    @Test func previewModeMovesNothing() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/w2.pdf")
        let (db, pipeline, _) = try setup(fx, answers: ["w2.pdf": ("f2", 0.99)])
        var s = try db.settings()
        s.previewMode = true
        try db.save(s)
        let run = try await pipeline.run(trigger: "test")
        #expect(run.moved == 0 && run.pending == 1)
        #expect(fx.exists("Inbox/w2.pdf"))
        #expect(try db.history().first?.status == .preview)
    }

    @Test func invalidScopeRunsNothing() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/w2.pdf")
        fx.scope.root = nil
        let (_, pipeline, classifier) = try setup(fx, answers: ["w2.pdf": ("f2", 0.99)])
        let run = try await pipeline.run(trigger: "test")
        #expect(run.error?.contains("Scope") == true)
        #expect(classifier.seen.files.isEmpty && fx.exists("Inbox/w2.pdf"))
    }

    @Test func inProgressDownloadsAreSkipped() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/movie.mp4.crdownload")
        try fx.file("Inbox/thing.part")
        let (_, pipeline, _) = try setup(fx, answers: [:])
        #expect(try await pipeline.run(trigger: "test").candidates == 0)
    }
}

@Suite("Rules, import, store")
struct SupportTests {
    @Test func ruleMatching() {
        func st(_ name: String, _ from: [String]? = nil, _ uti: String? = nil) -> FileState {
            FileState(name: name, ext: (name as NSString).pathExtension.lowercased(), contentType: uti, whereFrom: from)
        }
        #expect(RuleEngine.matches(Rule(folderID: "a", kind: .fileExtension, pattern: ".PDF"), st("x.pdf")))
        #expect(RuleEngine.matches(Rule(folderID: "a", kind: .nameGlob, pattern: "Screenshot*"), st("screenshot 2025.png")))
        #expect(RuleEngine.matches(Rule(folderID: "a", kind: .sourceDomain, pattern: "chase.com"), st("s.pdf", ["https://secure.chase.com/x"])))
        #expect(!RuleEngine.matches(Rule(folderID: "a", kind: .sourceDomain, pattern: "chase.com"), st("s.pdf", ["https://notchase.com/x"])))
        #expect(RuleEngine.matches(Rule(folderID: "a", kind: .contentType, pattern: "public.image"), st("a.png", nil, "public.png")))
    }

    @Test func rulesForDisallowedFoldersAreIgnored() throws {
        let fx = try Fixture()
        fx.scope.folders[0].allowed = false
        let engine = RuleEngine(rules: [Rule(folderID: "f1", kind: .fileExtension, pattern: "pdf")], scope: fx.scope)
        #expect(engine.match(FileState(name: "a.pdf", ext: "pdf")) == nil)
    }

    @Test func folderImportReadsTreeAndKeepsExistingIDs() throws {
        let fx = try Fixture()
        try FileManager.default.createDirectory(atPath: fx.root + "/Finance/Taxes/2025", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fx.root + "/Apps/Tool.app", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fx.root + "/.git", withIntermediateDirectories: true)
        var existing = fx.scope.folders
        existing[1].description = "tax stuff"
        existing[1].allowed = false
        let folders = FolderImport.folders(under: fx.root, merging: existing)
        let paths = folders.map(\.relativePath)
        #expect(paths.contains("Finance/Taxes/2025") && paths.contains("Apps"))
        #expect(!paths.contains { $0.contains(".app") || $0.contains(".git") })
        let taxes = try #require(folders.first { $0.relativePath == "Finance/Taxes" })
        #expect(taxes.id == "f2" && taxes.description == "tax stuff" && !taxes.allowed)
        #expect(Set(folders.map(\.id)).count == folders.count)
    }

    @Test func databaseRoundTrips() throws {
        let fx = try Fixture()
        let db = try AppDatabase()
        try db.save(fx.scope)
        #expect(try db.scope() == fx.scope)
        var s = AppSettings()
        s.intervalMinutes = 15
        s.confidenceThreshold = 0.8
        s.previewMode = true
        try db.save(s)
        #expect(try db.settings() == s)
        try db.save(rules: [Rule(folderID: "f1", kind: .nameGlob, pattern: "*.pdf")])
        var smaller = fx.scope
        smaller.folders.removeFirst()
        try db.save(smaller)  // deleting a folder deletes its rules
        #expect(try db.rules().isEmpty)
        #expect(try db.scope().folders.count == 3)
    }
}
