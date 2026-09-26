import Foundation
import Testing
@testable import JevFolderSortCore

/// Shared setup: a fixture, a database holding its scope, and one pipeline run.
private func sorted(_ fx: Fixture, _ answers: [String: (String, Double)]) async throws -> (AppDatabase, Actions) {
    let db = try AppDatabase()
    try db.save(fx.scope)
    let pipeline = Pipeline(db: db, classifier: ScriptedClassifier(answers: answers), policy: fx.policy,
                            scanner: Scanner(stabilityDelay: .milliseconds(10)))
    try await pipeline.run(trigger: "test")
    return (db, Actions(db: db, policy: fx.policy))
}

private func rerun(_ fx: Fixture, _ db: AppDatabase, _ answers: [String: (String, Double)]) async throws -> RunRecord {
    try await Pipeline(db: db, classifier: ScriptedClassifier(answers: answers), policy: fx.policy,
                       scanner: Scanner(stabilityDelay: .milliseconds(10))).run(trigger: "test")
}

@Suite("Undo")
struct UndoTests {
    @Test func undoPutsFileBackAndAsksInsteadOfResorting() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/w2.txt", "tax")
        let (db, actions) = try await sorted(fx, ["w2.txt": ("f3", 0.99)])  // wrongly to Photos
        #expect(fx.exists("Sorted/Photos/w2.txt"))
        let moved = try #require(try db.history().first { $0.status == .moved })

        guard case .success = try actions.undo(entryID: moved.id!) else { Issue.record("undo failed"); return }
        #expect(fx.exists("Inbox/w2.txt") && !fx.exists("Sorted/Photos/w2.txt"))
        #expect(try db.entry(id: moved.id!)?.undoneAt != nil)
        #expect(try db.pendingItems().first?.reason.hasPrefix("undone") == true)

        // The next scan must not move it straight back.
        let again = try await rerun(fx, db, ["w2.txt": ("f3", 0.99)])
        #expect(again.moved == 0 && fx.exists("Inbox/w2.txt"))

        // Undoing twice is refused.
        guard case .failure(.cannotUndo) = try actions.undo(entryID: moved.id!) else { Issue.record("double undo"); return }
    }

    @Test func undoRefusesIfFileWasChangedOrScopeNoLongerCoversIt() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/a.txt")
        try fx.file("Inbox/b.txt")
        let (db, actions) = try await sorted(fx, ["a.txt": ("f1", 0.99), "b.txt": ("f1", 0.99)])
        let entries = try db.history().filter { $0.status == .moved }
        #expect(entries.count == 2)

        // a.txt replaced by a different file at the same path.
        let a = try #require(entries.first { $0.fileName == "a.txt" })
        try FileManager.default.removeItem(atPath: a.destinationPath!)
        try fx.file(a.destinationPath!, "impostor")
        guard case .failure(.cannotUndo) = try actions.undo(entryID: a.id!) else { Issue.record("undid an impostor"); return }
        #expect(fx.read(a.destinationPath!) == "impostor")

        // Inbox is no longer watched: can't put b.txt back there.
        var scope = fx.scope
        try FileManager.default.createDirectory(atPath: fx.home + "/Inbox2", withIntermediateDirectories: true)
        scope.sources = [fx.home + "/Inbox2"]
        try db.save(scope)
        let b = try #require(entries.first { $0.fileName == "b.txt" })
        guard case .failure(.cannotUndo) = try actions.undo(entryID: b.id!) else { Issue.record("undid outside scope"); return }
        #expect(fx.exists("Sorted/Finance/b.txt"))
    }

    @Test func undoNeverOverwritesAndUndoRunUndoesEverything() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/x.txt", "original")
        try fx.file("Inbox/y.txt")
        let (db, actions) = try await sorted(fx, ["x.txt": ("f4", 0.99), "y.txt": ("f4", 0.99)])
        try fx.file("Inbox/x.txt", "newcomer")  // a new file took the old name
        let run = try #require(try db.history().first { $0.status == .moved }).runID
        let result = try actions.undo(runID: run)
        #expect(result.undone == 2 && result.failed.isEmpty)
        #expect(fx.read("Inbox/x.txt") == "newcomer")
        #expect(fx.read("Inbox/x 2.txt") == "original")
        #expect(fx.exists("Inbox/y.txt"))
    }
}

@Suite("Review")
struct ReviewTests {
    @Test func filingFromReviewMovesThroughGuardAndLearns() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/unsure.txt", "Form W-2 wages")
        let (db, actions) = try await sorted(fx, ["unsure.txt": ("f1", 0.4)])
        let item = try #require(try db.pendingItems().first)
        #expect(item.suggestions.first?.folderPath == "Finance")

        let r = try actions.file(pendingPath: item.path, into: "f2", textLimitKB: 4)
        guard case .success = r else { Issue.record("\(r)"); return }
        #expect(fx.exists("Sorted/Finance/Taxes/unsure.txt"))
        #expect(try db.pendingCount() == 0)
        let ex = try #require(try db.examples().first)
        #expect(ex.folderID == "f2" && ex.source == "review" && ex.state.text?.contains("W-2") == true)
        #expect(try db.history().first?.reason == "you")
    }

    @Test func reviewCannotEscapeScope() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/unsure.txt")
        let (db, actions) = try await sorted(fx, ["unsure.txt": ("f1", 0.4)])
        var scope = fx.scope
        scope.folders[2].allowed = false
        try db.save(scope)
        for bad in ["f3", "zzz", "../Outside"] {
            guard case .failure = try actions.file(pendingPath: fx.inbox + "/unsure.txt", into: bad, textLimitKB: 4) else {
                Issue.record("moved into \(bad)"); return
            }
        }
        #expect(fx.exists("Inbox/unsure.txt"))
        #expect(try db.examples().isEmpty)
    }

    @Test func ignoreLeavesFileAndIsNotReasked() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/meh.txt")
        let (db, actions) = try await sorted(fx, ["meh.txt": ("f1", 0.3)])
        try actions.ignore(pendingPath: fx.inbox + "/meh.txt")
        #expect(try db.pendingCount() == 0)
        let again = try await rerun(fx, db, [:])
        #expect(again.candidates == 0 && fx.exists("Inbox/meh.txt"))
    }
}

@Suite("Structure editor")
struct FolderEditorTests {
    @Test func createsOnlyInsideRoot() throws {
        let fx = try Fixture()
        #expect(try FolderEditor.createFolder(named: "Receipts", in: "Finance", config: fx.scope, policy: fx.policy).get() == "Finance/Receipts")
        #expect(ScopePaths.isDirectory(fx.root + "/Finance/Receipts"))
        #expect(try FolderEditor.createFolder(named: "Travel", in: nil, config: fx.scope, policy: fx.policy).get() == "Travel")
        for bad in ["", "..", ".hidden", "a/b", " padded", "x:y"] {
            #expect(throws: FolderEditor.Failure.badName(bad)) {
                try FolderEditor.createFolder(named: bad, in: nil, config: fx.scope, policy: fx.policy).get()
            }
        }
        #expect(throws: FolderEditor.Failure.parentMissing) {
            try FolderEditor.createFolder(named: "x", in: "../Outside", config: fx.scope, policy: fx.policy).get()
        }
        #expect(throws: FolderEditor.Failure.exists) {
            try FolderEditor.createFolder(named: "Photos", in: nil, config: fx.scope, policy: fx.policy).get()
        }
        #expect(!fx.exists("Outside/x"))
    }
}

@Suite("Learning signals")
struct LearningTests {
    @Test func bootstrapReadsAllowedFoldersOnly() throws {
        let fx = try Fixture()
        try fx.file("Sorted/Finance/Taxes/2024_w2.txt", "W-2 2024")
        try fx.file("Sorted/Photos/IMG_1.jpg")
        try fx.file("Sorted/Code/.secret")
        try fx.file("Outside/other.txt")
        fx.scope.folders[2].allowed = false  // Photos
        let db = try AppDatabase()
        try db.save(fx.scope)
        let n = try LearningCollector(db: db, policy: fx.policy).bootstrap(textLimitKB: 4)
        #expect(n == 1)
        let ex = try #require(try db.examples().first)
        #expect(ex.folderID == "f2" && ex.source == "bootstrap")
        #expect(fx.exists("Sorted/Finance/Taxes/2024_w2.txt"))  // read, never moved
    }

    @Test func userRefilingASortedFileBecomesACorrection() async throws {
        let fx = try Fixture()
        try fx.file("Inbox/statement.txt", "bank statement")
        let (db, _) = try await sorted(fx, ["statement.txt": ("f2", 0.99)])  // app put it in Taxes
        // The user drags it to Finance in Finder.
        try FileManager.default.moveItem(atPath: fx.root + "/Finance/Taxes/statement.txt", toPath: fx.root + "/Finance/statement.txt")
        let found = try LearningCollector(db: db, policy: fx.policy).detectImplicitCorrections(textLimitKB: 4)
        #expect(found == 1)
        let ex = try #require(try db.examples().first)
        #expect(ex.folderID == "f1" && ex.source == "implicit")
        #expect(try db.history().first { $0.status == .moved }?.correctedTo == "Finance")
        #expect(try LearningCollector(db: db, policy: fx.policy).detectImplicitCorrections(textLimitKB: 4) == 0)
    }
}
