import Foundation

// MARK: - Shared one-shot timer seam
//
// A cancellable timer abstraction shared by two features that both need a
// "run X seconds after the last event" cadence:
//   - `IdleDimmingController` (wall-panel dim: idle → blank screen)
//   - `ACController.polling` (live AC-state refresh on a fixed interval)
//
// Putting the seam in its own file keeps it on the *menu-bar* target's shared
// source set too, so the poller and dimmer share one timer design without the
// menu-bar binary pulling in the iOS-only brightness dimmer. Behind the protocol,
// production runs a real `Task`-backed timer; tests inject a manual scheduler
// that fires on demand -- the same fake-injection pattern used for `client:`.

public protocol IdleTimer: Sendable {
    func cancel()
}

/// Schedules a one-shot "time passed" callback `after` an interval.
public protocol IdleScheduler: Sendable {
    @discardableResult
    func schedule(after interval: TimeInterval, work: @escaping @Sendable () -> Void) -> any IdleTimer
}

/// Production scheduler: a cancellable `Task` that sleeps for the interval.
///
/// The work always runs on the main actor (the `Task` is `@MainActor`), which
/// is what the `@MainActor` controllers need.
public struct TaskIdleScheduler: IdleScheduler {
    public init() {}

    public func schedule(after interval: TimeInterval,
                         work: @escaping @Sendable () -> Void) -> any IdleTimer {
        TaskIdleTimer(after: interval, work: work)
     }
}

/// One pending, cancellable timer built on a `Task`.
///
/// Marked `@unchecked Sendable`: the only shared state is the optional `Task`
/// reference, mutated on a single path (a controller's main-actor reschedule),
/// so the invariant is trivially satisfied.
final class TaskIdleTimer: IdleTimer, @unchecked Sendable {
    private var task: Task<Void, Never>?

    init(after interval: TimeInterval, work: @escaping @Sendable () -> Void) {
        self.task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
             // A cancelled task wakes from `sleep` as a `CancellationError`
             // (swallowed by `try?`); don't fire a cancelled timer.
            guard !Task.isCancelled else { return }
            work()
          }
     }

    func cancel() {
        task?.cancel()
        task = nil
     }
}
