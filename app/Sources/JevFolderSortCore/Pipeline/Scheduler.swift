import Foundation

/// Runs the pipeline every N minutes and on demand. Never runs two at once,
/// and skips interval runs while paused or in Low Power Mode.
@MainActor
public final class Scheduler {
    public typealias Job = @MainActor (_ trigger: String) async -> Void

    private let job: Job
    private var loop: Task<Void, Never>?
    public private(set) var isRunning = false
    public var intervalMinutes: Int
    public var paused = false

    public init(intervalMinutes: Int, job: @escaping Job) {
        self.intervalMinutes = intervalMinutes
        self.job = job
    }

    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.intervalMinutes ?? 10
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard let self, !Task.isCancelled else { return }
                if !self.paused, !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    await self.trigger("interval")
                }
            }
        }
    }

    /// Restart the countdown (e.g. after the interval setting changes).
    public func reschedule(intervalMinutes: Int) {
        self.intervalMinutes = intervalMinutes
        start()
    }

    public func trigger(_ reason: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await job(reason)
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
