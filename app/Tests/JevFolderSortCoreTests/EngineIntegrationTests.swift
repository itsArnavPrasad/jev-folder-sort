import Foundation
import Testing
@testable import JevFolderSortCore

private let engineDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../../../engine").standardized.path
private let hasEngine = FileManager.default.isExecutableFile(atPath: engineDir + "/.venv/bin/python")

@Suite("Real engine (stub mode, sandboxed)", .enabled(if: hasEngine, "run `uv sync` in engine/ first"))
struct EngineIntegrationTests {
    @Test func healthAndEndToEndSort() async throws {
        let client = EngineClient(launch: try .development(engineDirectory: engineDir, stub: true), timeout: .seconds(60))
        let health = try await client.start()
        #expect(health.protocolVersion == EngineClient.protocolVersion)
        #expect(health.kind == "stub")

        let fx = try Fixture(folders: ["Finance", "Finance/Taxes", "Photos", "Code"])
        fx.scope.folders[1].description = "tax returns, W-2"
        try fx.file("Inbox/2025_W2_tax_return.txt", "Form W-2 Wage and Tax Statement 2025")
        try fx.file("Inbox/random_blob.bin")
        try fx.file("Outside/tax.txt", "tax W-2 taxes")  // same content, out of scope

        let db = try AppDatabase()
        try db.save(fx.scope)
        let run = try await Pipeline(db: db, classifier: client, policy: fx.policy,
                                     scanner: Scanner(stabilityDelay: .milliseconds(10))).run(trigger: "test")
        #expect(run.error == nil)
        #expect(fx.exists("Sorted/Finance/Taxes/2025_W2_tax_return.txt"))
        #expect(fx.exists("Inbox/random_blob.bin"))   // nothing fits -> stays
        #expect(fx.exists("Outside/tax.txt"))         // never in scope
        await client.stop()
    }

    /// A response far larger than one pipe read must be reassembled in order.
    @Test func largeBatchesRoundTripIntact() async throws {
        let client = EngineClient(launch: try .development(engineDirectory: engineDir, stub: true), timeout: .seconds(60))
        let tree = (1...40).map { EngineFolder(id: "f\($0)", path: "Folder \($0)/Sub", description: "things about topic \($0)") }
        let files = (0..<300).map { i in
            EngineFile(id: "c\(i)", state: FileState(name: "topic \(i % 40 + 1) notes.txt", ext: "txt",
                                                    text: String(repeating: "topic \(i % 40 + 1) ", count: 50)))
        }
        let results = try await client.classify(tree: tree, files: files)
        #expect(results.map(\.file) == files.map(\.id))
        #expect(results.allSatisfy { r in r.choice == EngineDecision.noneID || tree.contains { $0.id == r.choice } })
        await client.stop()
    }
}
