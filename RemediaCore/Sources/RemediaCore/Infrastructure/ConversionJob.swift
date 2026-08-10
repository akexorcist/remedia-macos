import Foundation

public struct NotImplementedError: Error, Sendable {
    public let feature: String
    public init(_ feature: String) { self.feature = feature }
}

/// Thread-safe cancellation flag engines can poll from non-async contexts —
/// AVFoundation's `requestMediaDataWhenReady` callbacks run on a plain
/// GCD queue with no ambient Swift Task, so `Task.isCancelled` wouldn't
/// observe cancellation there. Backed by a lock rather than the actor so it
/// can be read synchronously mid-loop.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// One running conversion. Reports progress (0...1) and supports cancellation,
/// which deletes any partial output file (REQUIREMENTS §8).
public actor ConversionJob {
    public enum State: Sendable {
        case running
        case completed(URL)
        case failed(Error)
        case cancelled
    }

    public private(set) var state: State = .running
    public let progress: AsyncStream<Double>
    nonisolated private let progressContinuation: AsyncStream<Double>.Continuation
    nonisolated private let cancelFlag = CancelFlag()
    private var partialOutputURL: URL?

    public init() {
        var continuation: AsyncStream<Double>.Continuation!
        self.progress = AsyncStream { continuation = $0 }
        self.progressContinuation = continuation
    }

    /// Synchronous cancellation check for engines running inside non-async
    /// callback loops (e.g. AVAssetReader/Writer's requestMediaDataWhenReady).
    nonisolated public var isCancelledSync: Bool {
        cancelFlag.isCancelled
    }

    /// Synchronous progress report for the same non-async callback contexts.
    nonisolated public func reportSync(progress value: Double) {
        progressContinuation.yield(value)
    }

    public func cancel() {
        guard case .running = state else { return }
        cancelFlag.set()
        state = .cancelled
        progressContinuation.finish()
        deletePartialOutputIfNeeded()
    }

    public func report(progress value: Double) {
        guard case .running = state else { return }
        progressContinuation.yield(value)
    }

    public func trackPartialOutput(_ url: URL) {
        partialOutputURL = url
    }

    public func complete(with url: URL) {
        guard case .running = state else { return }
        state = .completed(url)
        progressContinuation.finish()
    }

    public func fail(with error: Error) {
        guard case .running = state else { return }
        state = .failed(error)
        progressContinuation.finish()
        deletePartialOutputIfNeeded()
    }

    private func deletePartialOutputIfNeeded() {
        guard let url = partialOutputURL else { return }
        try? FileManager.default.removeItem(at: url)
        partialOutputURL = nil
    }
}
