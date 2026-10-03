import Foundation

/// Runs work on the main actor after a delay. `.main` uses the main queue; tests substitute a
/// clock they advance by hand, so settle delays and re-check timers run without sleeping.
struct HUDScheduler {
    var schedule: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> HUDScheduledWork

    @MainActor
    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> HUDScheduledWork {
        schedule(delay, work)
    }

    static let main = HUDScheduler { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return HUDScheduledWork { item.cancel() }
    }
}

/// Work a `HUDScheduler` has scheduled; `cancel()` keeps it from running.
final class HUDScheduledWork {
    private var onCancel: (() -> Void)?

    init(cancel: @escaping () -> Void) { onCancel = cancel }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}
