import Foundation

/// The time `SpeechStreamer` measures and waits by: `now` for its metrics and `schedule` for
/// releasing a first chunk when the stream pauses. `SystemSpeechClock` is the real one; a test
/// supplies a clock it advances by hand.
@MainActor
public protocol SpeechClock: AnyObject {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    /// Runs `action` once after `delay` seconds unless the returned timer is cancelled first.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SpeechClockTimer
}

/// A scheduled `SpeechClock` action; `cancel()` keeps it from running.
public struct SpeechClockTimer {
    private let onCancel: @MainActor () -> Void

    public init(cancel: @escaping @MainActor () -> Void) {
        onCancel = cancel
    }

    @MainActor public func cancel() {
        onCancel()
    }
}

/// System uptime, and timers on the main actor.
@MainActor
public final class SystemSpeechClock: SpeechClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SpeechClockTimer {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return SpeechClockTimer { task.cancel() }
    }
}
