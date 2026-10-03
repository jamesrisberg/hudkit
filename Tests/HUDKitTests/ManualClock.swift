import Foundation
@testable import HUDKit

/// A clock tests advance by hand, so delayed work (settle delays, Space checks, re-check
/// timers) runs without sleeping.
@MainActor
final class ManualClock {
    private struct Item {
        let id: Int
        let at: TimeInterval
        let work: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var cancelled = Set<Int>()
    private var nextID = 0

    var scheduler: HUDScheduler {
        HUDScheduler { [unowned self] delay, work in self.add(after: delay, work) }
    }

    /// Work scheduled and neither run nor cancelled.
    var pendingCount: Int { items.filter { !cancelled.contains($0.id) }.count }

    /// Delays of the pending work, from now.
    var pendingDelays: [TimeInterval] {
        items.filter { !cancelled.contains($0.id) }.map { $0.at - now }.sorted()
    }

    private func add(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> HUDScheduledWork {
        nextID += 1
        let id = nextID
        items.append(Item(id: id, at: now + delay, work: work))
        return HUDScheduledWork { [weak self] in _ = self?.cancelled.insert(id) }
    }

    /// Moves time forward by `interval`, running due work in time order (including work that
    /// work run here schedules, if it falls due within the interval).
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = items.filter({ !cancelled.contains($0.id) && $0.at <= target + 1e-9 })
            .min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            items.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.work()
        }
        now = target
        items.removeAll { cancelled.contains($0.id) }
    }
}
