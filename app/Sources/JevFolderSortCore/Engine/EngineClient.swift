import Foundation

public struct EngineFolder: Encodable, Sendable {
    public let id: String
    public let path: String
    public let description: String
}

public struct EngineFile: Encodable, Sendable {
    public let id: String
    public let state: FileState
}

public struct EngineDecision: Decodable, Equatable, Sendable {
    public struct Suggestion: Decodable, Equatable, Sendable {
        public let folder: String
        public let p: Double
    }

    public let file: String
    public let choice: String
    public let confidence: Double
    public let top: [Suggestion]
    public let latencyMs: Double

    enum CodingKeys: String, CodingKey { case file, choice, confidence, top, latencyMs = "latency_ms" }

    /// The engine's reserved "none of these folders fit" answer.
    public static let noneID = "__none__"
}

public struct EngineHealth: Decodable, Equatable, Sendable {
    public let protocolVersion: Int
    public let model: String
    public let kind: String
    public let device: String

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", model, kind, device }
}

public enum EngineError: Error, CustomStringConvertible {
    case notConfigured(String)
    case launchFailed(String)
    case protocolMismatch(Int)
    case timeout
    case engineError(String)
    case exited

    public var description: String {
        switch self {
        case .notConfigured(let m): "engine not configured: \(m)"
        case .launchFailed(let m): "engine failed to start: \(m)"
        case .protocolMismatch(let v): "engine speaks protocol \(v), app expects \(EngineClient.protocolVersion)"
        case .timeout: "engine timed out"
        case .engineError(let m): "engine error: \(m)"
        case .exited: "engine exited"
        }
    }
}

/// Anything that can answer "which folder id?" — the real engine, or a test double.
public protocol FolderClassifier: Sendable {
    func classify(tree: [EngineFolder], files: [EngineFile]) async throws -> [EngineDecision]
}

public struct EngineLaunch: Sendable {
    public var python: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String] = [:]
    /// Writable by the engine (the sandbox allows nothing else): holds `user/`.
    public var modelDirectory: String
    /// Read-only shipped checkpoint.
    public var baseCheckpoint: String?
    public var stub = false

    public var userCheckpoint: String { modelDirectory + "/user" }

    /// Which checkpoint to serve: the personalised one if it exists, else base.
    public var activeCheckpoint: String? {
        if FileManager.default.fileExists(atPath: userCheckpoint + "/model.safetensors") { return userCheckpoint }
        return baseCheckpoint
    }

    func serverArguments(stubOverride: Bool? = nil) -> [String] {
        let stub = stubOverride ?? self.stub
        guard !stub, let checkpoint = activeCheckpoint else { return arguments + ["--stub"] }
        return arguments + ["--model", checkpoint]
    }

    /// The engine bundled inside the .app (release builds), if present.
    public static func bundled(modelDirectory: String, stub: Bool) -> EngineLaunch? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let root = res + "/engine"
        let python = root + "/python/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
        let base = root + "/checkpoints/base"
        return EngineLaunch(
            python: python, arguments: ["-s", "-m", "jevsort_engine.server"], workingDirectory: root,
            environment: ["PYTHONPATH": root + "/app:" + root + "/site-packages", "PYTHONNOUSERSITE": "1",
                          "PYTHONDONTWRITEBYTECODE": "1"],
            modelDirectory: modelDirectory,
            baseCheckpoint: FileManager.default.fileExists(atPath: base + "/model.safetensors") ? base : nil, stub: stub)
    }

    /// `engineDirectory` is the repo's `engine/` folder (a uv project).
    public static func development(engineDirectory: String, stub: Bool, modelDirectory: String? = nil) throws -> EngineLaunch {
        let dir = (engineDirectory as NSString).expandingTildeInPath
        let python = dir + "/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw EngineError.notConfigured("no Python at \(python) — run `uv sync` in the engine folder")
        }
        let base = dir + "/checkpoints/base"
        return EngineLaunch(
            python: python, arguments: ["-m", "jevsort_engine.server"], workingDirectory: dir,
            modelDirectory: modelDirectory ?? dir + "/checkpoints",
            baseCheckpoint: FileManager.default.fileExists(atPath: base + "/model.safetensors") ? base : nil, stub: stub)
    }
}

public struct TrainReport: Codable, Equatable, Sendable {
    public var examples: Int
    public var dropped: Int?
    public var activated: Bool
    public var reason: String?
    public var holdout: Int?
    public var newAccuracy: Double?
    public var currentAccuracy: Double?
    public var steps: Int?
    public var seconds: Double?
    public var version: String?

    enum CodingKeys: String, CodingKey {
        case examples, dropped, activated, reason, holdout, steps, seconds, version
        case newAccuracy = "new_accuracy", currentAccuracy = "current_accuracy"
    }
}

/// Runs the Python engine as a child process under a macOS sandbox profile:
/// no network, and no file writes outside its model and temp directories.
/// The engine never receives file paths — only extracted state and opaque ids.
public actor EngineClient: FolderClassifier {
    public static let protocolVersion = 1
    static let sandboxProfile = """
    (version 1)
    (allow default)
    (deny network*)
    (allow network* (remote unix-socket))
    (deny file-write*)
    (allow file-write*
        (subpath (param "MODEL_DIR"))
        (subpath "/private/var/folders")
        (subpath "/private/tmp")
        (literal "/dev/null")
        (literal "/dev/dtracehelper"))
    """

    private let launch: EngineLaunch
    private let timeout: Duration
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var generation: UUID?
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    public private(set) var health: EngineHealth?

    private let stubOverride: Bool?

    /// `stubOverride: true` starts the engine without loading a model (used for training jobs).
    public init(launch: EngineLaunch, timeout: Duration = .seconds(120), stubOverride: Bool? = nil) {
        self.launch = launch
        self.timeout = timeout
        self.stubOverride = stubOverride
    }

    public func start() async throws -> EngineHealth {
        if process?.isRunning == true, let health { return health }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        try? FileManager.default.createDirectory(atPath: launch.modelDirectory, withIntermediateDirectories: true)
        p.arguments = ["-p", Self.sandboxProfile, "-D", "MODEL_DIR=\(launch.modelDirectory)", launch.python]
            + launch.serverArguments(stubOverride: stubOverride)
        p.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        for (k, v) in launch.environment { env[k] = v }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        // Chunks must be consumed in arrival order, so they go through one
        // ordered stream and a single reader task, not a Task per chunk.
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil  // EOF
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
        let generation = UUID()
        p.terminationHandler = { [weak self] _ in Task { await self?.exited(generation) } }
        do { try p.run() } catch { throw EngineError.launchFailed(error.localizedDescription) }
        process = p
        self.generation = generation
        stdin = inPipe.fileHandleForWriting
        buffer.removeAll()
        reader = Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
        }

        let json = try await request(["op": "health"])
        let data = try JSONSerialization.data(withJSONObject: json)
        let h = try JSONDecoder().decode(EngineHealth.self, from: data)
        guard h.protocolVersion == Self.protocolVersion else {
            stop()
            throw EngineError.protocolMismatch(h.protocolVersion)
        }
        health = h
        return h
    }

    public func stop() {
        if let stdin, process?.isRunning == true {
            try? stdin.write(contentsOf: Data(#"{"op":"shutdown"}"#.utf8 + [0x0A]))
        }
        process?.terminate()
        exitedNow()
    }

    private func exitedNow() {
        if let generation { exited(generation) }
    }

    public func classify(tree: [EngineFolder], files: [EngineFile]) async throws -> [EngineDecision] {
        if process?.isRunning != true { _ = try await start() }  // restart after a crash
        let body: [String: Any] = [
            "op": "classify",
            "tree": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)),
            "files": try JSONSerialization.jsonObject(with: JSONEncoder().encode(files)),
        ]
        let json = try await request(body)
        let data = try JSONSerialization.data(withJSONObject: json["results"] ?? [])
        return try JSONDecoder().decode([EngineDecision].self, from: data)
    }

    /// Fine-tune on the user's examples (M6). Runs in this engine process;
    /// writes only to `launch.userCheckpoint` (inside the sandbox's MODEL_DIR).
    public func train(tree: [EngineFolder], examples: [(state: FileState, folderID: String)], steps: Int? = nil) async throws -> TrainReport {
        if process?.isRunning != true { _ = try await start() }
        guard let base = launch.baseCheckpoint else { throw EngineError.notConfigured("no base checkpoint to personalise") }
        let encoded = try examples.map { e -> [String: Any] in
            ["state": try JSONSerialization.jsonObject(with: JSONEncoder().encode(e.state)), "target": e.folderID]
        }
        var body: [String: Any] = [
            "op": "train_user", "base": base, "out": launch.userCheckpoint,
            "tree": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)), "examples": encoded,
        ]
        if FileManager.default.fileExists(atPath: launch.userCheckpoint + "/model.safetensors") {
            body["current"] = launch.userCheckpoint
        }
        if let steps { body["steps"] = steps }
        let json = try await request(body)
        let data = try JSONSerialization.data(withJSONObject: json["report"] ?? [:])
        return try JSONDecoder().decode(TrainReport.self, from: data)
    }

    /// Forget the personalised model (the engine deletes its own `user/` directory).
    public func resetUserModel() async throws {
        if process?.isRunning != true { _ = try await start() }
        _ = try await request(["op": "reset_user", "out": launch.userCheckpoint])
    }

    private func request(_ body: [String: Any]) async throws -> [String: Any] {
        guard let stdin else { throw EngineError.exited }
        nextID += 1
        let id = nextID
        var payload = body
        payload["id"] = id
        let line = try JSONSerialization.data(withJSONObject: payload) + [0x0A]
        let timeout = self.timeout
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id: id, with: EngineError.timeout)
        }
        defer { timer.cancel() }
        let response = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            pending[id] = c
            do { try stdin.write(contentsOf: line) } catch {
                pending.removeValue(forKey: id)?.resume(throwing: EngineError.exited)
            }
        }
        guard response["ok"] as? Bool == true else {
            throw EngineError.engineError(response["error"] as? String ?? "unknown")
        }
        return response
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int, let c = pending.removeValue(forKey: id)
            else { continue }
            c.resume(returning: obj)
        }
    }

    private func fail(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func exited(_ which: UUID) {
        guard which == generation else { return }  // an older process we already replaced
        generation = nil
        reader?.cancel()
        reader = nil
        process = nil
        stdin = nil
        health = nil
        for (_, c) in pending { c.resume(throwing: EngineError.exited) }
        pending.removeAll()
    }
}
