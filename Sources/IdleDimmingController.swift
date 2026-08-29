import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Keeps a wall/panel deployment blank when nobody is in front of it.
///
/// The device (an old iPhone SE mounted as a touch panel) should never sleep,
/// but after `idleDelay` seconds of **no user movement** it should present a
/// black screen so it is invisible until someone touches it. Any touch wakes the
/// screen and restarts the countdown.
///
/// A single `registerActivity()` call is the whole "user moved" signal: it both
/// *wakes* a black screen (clears `isDimmed`) and *resets* the idle countdown,
/// so the view layer has exactly one thing to call on any gesture.
///
///
/// Design notes
/// ------------
/// Wall mode combines two actions when idle: an opaque black overlay covers the
/// UI, and `UIScreen.main.brightness` is lowered through `ScreenBrightnessControlling`.
/// The overlay makes the panel visually blank; the hardware brightness change
/// reduces LCD backlight load on long-running wall installs. The companion switch
/// that truly prevents the OS from locking the device
/// (`UIApplication.isIdleTimerDisabled`) is flipped by `KioskAppDelegate`.
///
/// The timer is behind the `IdleScheduler` seam so the controller is testable
/// without real `Task.sleep`s: production uses `TaskIdleScheduler`, tests use a
/// manual scheduler that fires on demand. This mirrors the existing pattern of
/// injecting `client:` for a hermetic unit test.
public protocol IdleTimer: Sendable {
    func cancel()
}

/// Schedules a one-shot "time passed" callback `after` an interval.
public protocol IdleScheduler: Sendable {
    @discardableResult
    func schedule(after interval: TimeInterval, work: @escaping @Sendable () -> Void) -> any IdleTimer
}

/// Minimal screen-brightness seam. Production uses `UIScreen.main`; unit tests
/// inject a fake so they never change the developer's simulator or device.
@MainActor
public protocol ScreenBrightnessControlling: AnyObject {
    var brightness: Double { get set }
}

final class SystemScreenBrightnessController: ScreenBrightnessControlling {
    var brightness: Double {
        get {
            #if canImport(UIKit)
            return Double(UIScreen.main.brightness)
            #else
            return 1.0
            #endif
        }
        set {
            #if canImport(UIKit)
            UIScreen.main.brightness = CGFloat(Self.clamped(newValue))
            #endif
        }
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}

/// Production scheduler: a cancellable `Task` that sleeps for the interval.
///
/// The work always runs on the main actor (the `Task` is `@MainActor`), which
/// is what the `@MainActor` controller needs.
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
/// reference, mutated on a single path (the controller's main-actor `reschedule`),
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

@MainActor
final class IdleDimmingController: ObservableObject, @unchecked Sendable {
    /// `true` while the black overlay should cover the UI. The view binds to this.
     @Published private(set) var isDimmed = false

     /// Whether the feature is on at all. When `false` the controller is inert:
      /// it never dims and ignores every `registerActivity()` call, so the view
      /// layer can attach the idle wiring unconditionally with zero behaviour
      /// change for non-panel installs.
     var enabled: Bool

     /// Seconds of no movement before the screen goes blank.
     var idleDelay: TimeInterval

     private let scheduler: any IdleScheduler
     private let screen: any ScreenBrightnessControlling
     private let dimBrightness: Double
     private var timer: (any IdleTimer)?
     private var savedBrightness: Double?

     /// Production entry point: real `Task`-backed timer.
    public init(enabled: Bool = true, idleDelay: TimeInterval = 2.0,
                dimBrightness: Double = 0.01,
                scheduler: any IdleScheduler = TaskIdleScheduler(),
                screen: any ScreenBrightnessControlling = SystemScreenBrightnessController()) {
        self.enabled = enabled
         self.idleDelay = idleDelay
        self.dimBrightness = Self.clamped(dimBrightness)
        self.scheduler = scheduler
        self.screen = screen
         start()
     }

     // MARK: - Lifecycle

     private func start() {
        if enabled {
            reschedule()
          } else {
            isDimmed = false
          }
      }

     /// Called when the scene becomes inactive/backgrounded (e.g. a Settings flip
      /// in Guided Access). Pause the countdown so we don't blank a screen the
      /// user is not looking at; `registerActivity()` reschedules on return.
    func sceneInactive() {
        guard enabled else { return }
       timer?.cancel()
       timer = nil
       isDimmed = false
       restoreBrightness()
      }

     // MARK: - Activity / wake (single entry point)

     /// "The user made a move." Wakes a black screen and restarts the countdown.
      /// No-op when disabled.
    func registerActivity() {
        guard enabled else { return }
        restoreBrightness()
        isDimmed = false         // wake — clears the overlay if it was up
        reschedule()             // start a fresh countdown
      }

     /// Change the idle delay at runtime (e.g. from config). Reschedules the
      /// countdown so the new value takes effect on the next quiet period.
    func setInterval(_ seconds: TimeInterval) {
        guard seconds != idleDelay else { return }
        idleDelay = seconds
        reschedule()
      }

     /// Enable/disable the feature at runtime.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            reschedule()
          } else {
            timer?.cancel()
            timer = nil
            restoreBrightness()
            isDimmed = false
          }
      }

     // MARK: - Timer plumbing

     /// Cancel any pending timer and schedule a fresh dim `idleDelay` out.
    private func reschedule() {
        timer?.cancel()
        guard enabled else { return }
        timer = scheduler.schedule(after: idleDelay) { [weak self] in
            // `work` may be invoked from a main-actor `Task` (production) or
            // synchronously on main by a test scheduler. Assert main so a
            // `@Published` write is always correct.
            MainActor.assumeIsolated {
                guard let self else { return }
                    self.dim()
             }
         }
     }

     private func dim() {
        timer = nil
        if savedBrightness == nil {
            savedBrightness = screen.brightness
        }
        screen.brightness = dimBrightness
        isDimmed = true
     }

     private func restoreBrightness() {
        guard let original = savedBrightness else { return }
        screen.brightness = original
        savedBrightness = nil
     }

     private static func clamped(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
     }
    }
