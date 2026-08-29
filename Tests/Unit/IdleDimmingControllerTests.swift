import XCTest

@testable import SensiboToggle

/// A timer scheduler that never uses real time: `fireDue()` fires every pending
/// timer in order (simulate time passing), `cancelAll()` cancels them (simulate
/// new activity). This is the hermetic seam that lets the controller be tested
/// without a single `Task.sleep`.
final class ManualIdleScheduler: IdleScheduler, @unchecked Sendable {

     final class ManualTimer: IdleTimer, @unchecked Sendable {
        let interval: TimeInterval
        var work: @Sendable () -> Void
        private(set) var cancelled = false
        private(set) var fired = false

        init(after interval: TimeInterval, work: @escaping @Sendable () -> Void) {
            self.interval = interval
            self.work = work
          }
        func cancel() { cancelled = true }
        /// Fire this timer once; a no-op if it was cancelled or already fired.
        func fire() {
            guard !cancelled, !fired else { return }
            fired = true
            work()
          }
     }

     private(set) var pending: [ManualTimer] = []

     @discardableResult
    func schedule(after interval: TimeInterval, work: @escaping @Sendable () -> Void) -> any IdleTimer {
        pending.removeAll { $0.cancelled || $0.fired }
        let timer = ManualTimer(after: interval, work: work)
        pending.append(timer)
        return timer
       }

      /// Fire every live timer in order, then prune all resolved (fired/cancelled) ones.
    func fireDue() {
        for t in pending where !t.cancelled && !t.fired { t.fire() }
        pending.removeAll { $0.cancelled || $0.fired }
       }

     /// Cancel and drop every pending timer (what a fresh activity does internally).
    func cancelAll() {
        for t in pending { t.cancel() }
        pending.removeAll { $0.cancelled || $0.fired }
       }

      /// Number of live timers waiting to fire.
    var pendingCount: Int { pending.filter { !$0.cancelled && !$0.fired }.count }
      /// The interval of the most-recently scheduled (live) timer, if any.
    var liveInterval: TimeInterval? { pending.filter { !$0.cancelled && !$0.fired }.last?.interval }
}

@MainActor
final class FakeScreenBrightness: ScreenBrightnessControlling {
    var brightness: Double

    init(_ brightness: Double = 0.65) {
        self.brightness = brightness
    }
}

@MainActor
final class IdleDimmingControllerTests: XCTestCase {

     // MARK: - Disabled / inert

      /// When disabled the controller never blanks and ignores every signal, so the
       /// view layer can wire it unconditionally with zero behaviour change.
    func testDisabledDoesNotDim() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness()
        let c = IdleDimmingController(enabled: false, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        XCTAssertFalse(c.isDimmed)
        c.registerActivity()
        scheduler.fireDue()
        XCTAssertFalse(c.isDimmed, "disabled controller must never dim")
        XCTAssertEqual(screen.brightness, 0.65, accuracy: 0.0001)
         }

     // MARK: - Idle -> blank

      /// A countdown starts on launch; when it fires with no activity, it blanks.
    func testBlanksAfterIdleDelay() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness(0.7)
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        XCTAssertFalse(c.isDimmed)
        XCTAssertEqual(scheduler.pendingCount, 1, "a 2s countdown must be running at start")
        XCTAssertEqual(scheduler.liveInterval, 2.0)

        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed, "the screen must go blank after the idle delay")
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)
         }

     // MARK: - Any touch wakes + resets

      /// A touch (registerActivity) clears the blank and starts a fresh countdown
       /// — it does not simply let the old timer keep running.
    func testActivityWakesThenBlanksAgain() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness(0.72)
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed)
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)

        c.registerActivity()                 // "someone touched the wall"
        XCTAssertFalse(c.isDimmed, "a touch must wake the screen")
        XCTAssertEqual(screen.brightness, 0.72, accuracy: 0.0001)
        XCTAssertEqual(scheduler.pendingCount, 1, "a fresh countdown must be running")

        scheduler.fireDue()                  // nobody touched again
        XCTAssertTrue(c.isDimmed, "idling again must blank it again")
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)
        }

      /// Activity *before* the in-flight timer fires cancels that timer so it
       /// cannot blank the screen mid-activity — then a new one takes over.
    func testActivityCancelsInFlightTimer() {
        let scheduler = ManualIdleScheduler()
        let c = IdleDimmingController(enabled: true, idleDelay: 10.0,
                                      scheduler: scheduler, screen: FakeScreenBrightness())

        let first = scheduler.pending.first   // the only pending timer
        XCTAssertNotNil(first)

        c.registerActivity()                  // cancels the 10s timer, schedules anew
        // The original timer must be dead; exactly one live timer remains.
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(first?.cancelled ?? true, "the in-flight timer must be cancelled")
        XCTAssertEqual(scheduler.liveInterval, 10.0)

        // Still awake until the new countdown fires.
        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed)
        }

     // MARK: - Runtime reconfiguration

      /// `setInterval` swaps the countdown length and reschedules.
    func testSetIntervalReschedules() {
        let scheduler = ManualIdleScheduler()
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: FakeScreenBrightness())

        XCTAssertEqual(scheduler.liveInterval, 2.0)
        c.setInterval(10.0)

        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.liveInterval, 10.0, "new interval must take effect")
        }

      /// Turning the feature off cancels the countdown and un-blanks; it also
        /// stops dimming even after a fire.
    func testSetEnabledFalseCancelsAndUnblanks() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness(0.83)
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed)
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)

        c.setEnabled(false)
        XCTAssertFalse(c.isDimmed, "disabling must clear the blank")
        XCTAssertEqual(screen.brightness, 0.83, accuracy: 0.0001)
        XCTAssertEqual(scheduler.pendingCount, 0)

        scheduler.fireDue()
        XCTAssertFalse(c.isDimmed, "a disabled controller must not dim")
        }

     // MARK: - Scene lifecycle

      /// Backgrounding (Guided Access / Settings) pauses the countdown so we don't
       /// blank a screen nobody is looking at; returning re-arms it.
    func testSceneInactivePausesAndActiveResumes() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness(0.42)
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        c.sceneInactive()
        XCTAssertEqual(scheduler.pendingCount, 0, "backgrounding must cancel the timer")

        c.registerActivity()           // scene becomes active again
        XCTAssertEqual(scheduler.pendingCount, 1, "returning must re-arm the countdown")

        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed)
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)
       }

    func testSceneInactiveRestoresBrightnessIfAlreadyDimmed() {
        let scheduler = ManualIdleScheduler()
        let screen = FakeScreenBrightness(0.38)
        let c = IdleDimmingController(enabled: true, idleDelay: 2.0,
                                      scheduler: scheduler, screen: screen)

        scheduler.fireDue()
        XCTAssertTrue(c.isDimmed)
        XCTAssertEqual(screen.brightness, 0.01, accuracy: 0.0001)

        c.sceneInactive()
        XCTAssertFalse(c.isDimmed)
        XCTAssertEqual(screen.brightness, 0.38, accuracy: 0.0001)
    }
}
