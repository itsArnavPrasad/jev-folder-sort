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
    public var modelDirectory: String

    /// `engineDirectory` is the repo's `engine/` folder (a uv project).
    public static func development(engineDirectory: String, stub: Bool) throws -> EngineLaunch {
        let dir = (engineDirectory as NSString).expandingTildeInPath
        let python = dir + "/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw EngineError.notConfigured("no Python at \(python) — run `uv sync` in the engine folder")
        }
        let checkpoint = dir + "/checkpoints/base"
        let hasModel = FileManager.default.fileExists(atPath: checkpoint + "/model.safetensors")
        var args = ["-m", "jevsort_engine.server"]
        args += (stub || !hasModel) ? ["--stub"] : ["--model", checkpoint]
        return EngineLaunch(python: python, arguments: args, workingDirectory: dir, modelDirectory: dir + "/checkpoints")
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
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    public private(set) var health: EngineHealth?

    public init(launch: EngineLaunch, timeout: Duration = .seconds(120)) {
        self.launch = launch
        self.timeout = timeout
    }

    public func start() async throws -> EngineHealth {
        if process?.isRunning == true, let health { return health }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", Self.sandboxProfile, "-D", "MODEL_DIR=\(launch.modelDirectory)", launch.python] + launch.arguments
        p.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.exited() } }
        do { try p.run() } catch { throw EngineError.launchFailed(error.localizedDescription) }
        process = p
        stdin = inPipe.fileHandleForWriting

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
        process = nil
        health = nil
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

    private func exited() {
        process = nil
        stdin = nil
        health = nil
        for (_, c) in pending { c.resume(throwing: EngineError.exited) }
        pending.removeAll()
    }
}
