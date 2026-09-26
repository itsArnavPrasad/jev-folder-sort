import Foundation
import IOKit.ps

/// Decides when to personalise the model and runs the training job in a
/// separate, sandboxed engine process so sorting isn't blocked.
public struct Learner: Sendable {
    public static let minimumNewExamples = 20

    let db: AppDatabase
    let policy: ScopePolicy
    let launch: EngineLaunch

    public init(db: AppDatabase, policy: ScopePolicy = .system, launch: EngineLaunch) {
        self.db = db
        self.policy = policy
        self.launch = launch
    }

    public struct Status: Equatable, Sendable {
        public var examples: Int
        public var bySource: [String: Int]
        public var newSinceTraining: Int
        public var lastTrained: Date?
        public var lastReport: TrainReport?
        public var personalised: Bool
    }

    public func status() throws -> Status {
        let counts = try db.exampleCounts()
        let total = counts.values.reduce(0, +)
        let atLast = Int(try db.value("learning.examplesAtLastTrain") ?? "") ?? 0
        let report = try db.value("learning.lastReport").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(TrainReport.self, from: $0) }
        return Status(examples: total, bySource: counts, newSinceTraining: max(0, total - atLast),
                      lastTrained: (try db.value("learning.lastTrainedAt")).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                      lastReport: report,
                      personalised: FileManager.default.fileExists(atPath: launch.userCheckpoint + "/model.safetensors"))
    }

    /// Automatic retraining: enough new examples, learning on, on mains power.
    public func shouldTrainAutomatically() throws -> Bool {
        guard try db.settings().learningEnabled, launch.baseCheckpoint != nil, Self.onACPower() else { return false }
        return try status().newSinceTraining >= Self.minimumNewExamples
    }

    /// Bootstrap (first time), then fine-tune. Returns the engine's report.
    public func train(steps: Int? = nil) async throws -> TrainReport {
        let settings = try db.settings()
        let collector = LearningCollector(db: db, policy: policy)
        if (try db.exampleCounts()["bootstrap"] ?? 0) == 0 {
            try collector.bootstrap(textLimitKB: settings.textLimitKB)
        }
        let scope = try db.scope()
        let tree = scope.allowedFolders.map { EngineFolder(id: $0.id, path: $0.relativePath, description: $0.description) }
        let examples = try db.examples().map { (state: $0.state, folderID: $0.folderID) }

        let trainer = EngineClient(launch: launch, timeout: .seconds(1800), stubOverride: true)
        defer { Task { await trainer.stop() } }
        let report = try await trainer.train(tree: tree, examples: examples, steps: steps)
        try db.set("learning.lastTrainedAt", String(Date().timeIntervalSince1970))
        try db.set("learning.examplesAtLastTrain", String(examples.count))
        try db.set("learning.lastReport", String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        return report
    }

    public func reset() async throws {
        let trainer = EngineClient(launch: launch, stubOverride: true)
        try await trainer.resetUserModel()
        await trainer.stop()
        try db.set("learning.lastReport", nil)
        try db.set("learning.lastTrainedAt", nil)
        try db.set("learning.examplesAtLastTrain", nil)
    }

    public static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }  // desktops without a battery report nothing: treat as AC
        return type == kIOPMACPowerKey
    }
}
