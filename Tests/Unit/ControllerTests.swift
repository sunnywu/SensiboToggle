import XCTest
@testable import SensiboToggle

/// A controllable fake of the Sensibo client for hermetic controller tests.
///
/// `@MainActor` keeps all stored state single-threaded and trivially `Sendable`
/// (it matches how `ACController` reaches it). `failCurrent` makes `setCurrent`
/// throw so we can prove the controller reverts.
@MainActor
final class FakeClient: SensiboClientProtocol {
    var seed: [AirCon]
    var nextPodsResult: Result<[AirCon], Error>
     var failCurrent = false
     var blockCurrent = false
     private(set) var recordedSets: [(on: Bool, podId: String)] = []
     private(set) var recordedTemperatures: [(temperature: Double?, podId: String)] = []

    init(seed: [AirCon],
         nextPodsResult: Result<[AirCon], Error>? = nil) {
        self.seed = seed
        self.nextPodsResult = nextPodsResult ?? .success(seed)
            }

    func pods() async throws -> [AirCon] {
        switch self.nextPodsResult {
        case let .success(value): return value
        case let .failure(error): throw error
          }
       }

    func setCurrent(on: Bool, podId: String) async throws {
        if self.blockCurrent {
                // Freeze an in-flight toggle so a test can observe a stale poll
                // racing a still-pending tap without an async confirm clearing it.
                try? await Task.sleep(nanoseconds: .max)
              }
        self.recordedSets.append((on, podId))
        if self.failCurrent {
            throw SensiboError.http(status: 500, body: "boom")
            }
           }

    func setTemperature(_ temperature: Double?, for podId: String) async throws {
        self.recordedTemperatures.append((temperature, podId))
    }

          // Helper so tests can assert on recorded sets without tuple Equatable.
    var recordedKeys: [String] { self.recordedSets.map { "\($0.on)/\($0.podId)" } }
}

@MainActor
final class ControllerTests: XCTestCase {

        /// The core speed claim: a tap flips the UI *immediately*,
          /// before the server answers. Assert the optimistic value synchronously.
     func testToggleIsOptimisticImmediately() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "Room", on: false)])
        let controller = ACController(client: fake)
         _ = await controller.load()      // populate acs

        let task = controller.toggle("a")  // optimistic; server confirm is async
        _ = task

         // No await between toggle and assertion: the UI value already flipped.
        let current = controller.acs.filter { $0.id == "a" }.first
        XCTAssertEqual(current?.on, true, "optimistic update must be visible without waiting for the server")
        XCTAssertTrue(controller.pending.contains("a"))
         }

                /// Successful confirm commits and clears pending.
          func testSuccessfulToggleCommits() async {
            let fake = FakeClient(seed: [AirCon(id: "a", room: "Room", on: false)])
            let controller = ACController(client: fake)
             _ = await controller.load()

            let task = controller.toggle("a")
            await task.value

            XCTAssertTrue(controller.pending.isEmpty, "pending clears after confirm")
            XCTAssertEqual(controller.acs.first?.on, true, "committed to on")
            XCTAssertEqual(fake.recordedKeys, ["true/a"])
              }

                /// Failed confirm reverts the optimistic value and surfaces an error.
          func testFailedToggleReverts() async {
            let fake = FakeClient(seed: [AirCon(id: "a", room: "Room", on: true)])
            fake.failCurrent = true
            let controller = ACController(client: fake)
             _ = await controller.load()

            let task = controller.toggle("a")     // optimistic on -> off
            await task.value

            XCTAssertEqual(controller.acs.first?.on, true, "must revert to original on")
            XCTAssertNotNil(controller.error)
              }

                /// Load failure surfaces an error and never marks ready.
          func testLoadFailure() async {
            let fake = FakeClient(seed: [], nextPodsResult: .failure(SensiboError.transport("nope")))
            let controller = ACController(client: fake)
            let result = await controller.load()
            guard case .failure = result else { return XCTFail("expected failure") }
            XCTAssertFalse(controller.isReady)
            XCTAssertNotNil(controller.error)
              }

                /// Load success populates and marks ready.
          func testLoadSuccess() async {
            let fake = FakeClient(seed: [
                AirCon(id: "a", room: "Room A", on: true),
                AirCon(id: "b", room: "Room B", on: false),
                ])
            let controller = ACController(client: fake)
            let result = await controller.load()
            guard case .success(let list) = result else { return XCTFail("expected success") }
            XCTAssertEqual(list.map { $0.id }, ["a", "b"])
            XCTAssertTrue(controller.isReady)
              }
}

@MainActor
final class PollRefreshTests: XCTestCase {

        /// A poll brings on/off + temperature + mode + room changes made *elsewhere*
     /// (the Sensibo app, a remote, a schedule) into `acs`, so the UI auto-corrects
     /// without a user fetch.
    func testRefreshReconcilesChangedState() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "Bedroom 1", on: false, temperature: 20)])
        let c = ACController(client: fake, pollIntervalSeconds: 30, scheduler: ManualIdleScheduler())
          _ = await c.load()
        XCTAssertEqual(c.acs.first { $0.id == "a" }?.on, false)

          // The device was turned on and re-set to 24 cool, off-device:
        fake.nextPodsResult = .success([
            AirCon(id: "a", room: "Bedroom 1", on: true, temperature: 24, mode: "cool"),
           ])
        await c.refresh()

        let a = c.acs.first { $0.id == "a" }
        XCTAssertEqual(a?.on, true)
        XCTAssertEqual(a?.temperature, 24)
        XCTAssertEqual(a?.mode, "cool")
        XCTAssertEqual(a?.room, "Bedroom 1")
          }

          /// A stale poll must never clobber an in-flight optimistic toggle: while a tap
     /// is `pending`, a poll returning the pre-toggle server value leaves the UI on its
     /// optimistic value. `blockCurrent` freezes the confirm so `pending` stays set during
     /// the poll -- this is the determinism the invariant needs.
    func testRefreshNeverClobbersPendingToggle() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "Bedroom 1", on: false)])
        let c = ACController(client: fake, pollIntervalSeconds: 30, scheduler: ManualIdleScheduler())
          _ = await c.load()

        fake.blockCurrent = true                   // freeze the server confirm
        _ = c.toggle("a")                         // optimistic ON, still pending
        fake.nextPodsResult = .success([AirCon(id: "a", room: "Bedroom 1", on: false)])  // server still OFF
        await c.refresh()
        await Task.yield()

        XCTAssertEqual(c.acs.first { $0.id == "a" }?.on, true,
                      "a pending optimistic toggle must survive a stale poll")
        XCTAssertTrue(c.pending.contains("a"), "the in-flight confirm is still pending")
          }

          /// When a poll returns the same state, `acs` is left untouched (no needless UI churn).
    func testRefreshDoesNotChurnWhenUnchanged() async {
        let seed = [AirCon(id: "a", room: "A", on: true, temperature: 22)]
        let c = ACController(client: FakeClient(seed: seed), pollIntervalSeconds: 30,
                              scheduler: ManualIdleScheduler())
          _ = await c.load()
        let before = c.acs
        await c.refresh()
        XCTAssertEqual(c.acs, before, "an unchanged poll must not rewrite `acs`")
          }

          /// With the interval at 0, polling is inert: no timer is armed and a manual
     /// `refresh()` is an outright no-op.
    func testRefreshInertWhenDisabled() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "A", on: false)])
        let scheduler = ManualIdleScheduler()
        let c = ACController(client: fake, pollIntervalSeconds: 0, scheduler: scheduler)
          _ = await c.load()
        XCTAssertEqual(scheduler.pendingCount, 0, "no timer is armed when the interval is 0")

        fake.nextPodsResult = .success([AirCon(id: "a", room: "A", on: true)])
        await c.refresh()
        XCTAssertEqual(c.acs.first { $0.id == "a" }?.on, false, "a disabled poll never reconciles")
          }

          /// A device that only appears on a later poll is appended at the end, without
     /// reordering the rows already on screen.
    func testRefreshAppendsNewlyDiscoveredPods() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "A", on: true)])
        let c = ACController(client: fake, pollIntervalSeconds: 30, scheduler: ManualIdleScheduler())
          _ = await c.load()
        XCTAssertNil(c.acs.first { $0.id == "b" })

        fake.nextPodsResult = .success([
            AirCon(id: "a", room: "A", on: true),
            AirCon(id: "b", room: "B", on: false),
           ])
        await c.refresh()
        XCTAssertEqual(c.acs.map { $0.id }, ["a", "b"], "new pod appended, existing order preserved")
          }

          /// The poll loop is self-rescheduling: a positive interval arms one timer at
     /// launch and firing it re-arms exactly one more for the next tick.

    func testPollArmsAndReschedulesOneTimer() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "A", on: false)])
        let scheduler = ManualIdleScheduler()
          let c = ACController(client: fake, pollIntervalSeconds: 30, scheduler: scheduler)
        _ = c   // retain: the timer's work captures `self` weakly
        XCTAssertEqual(scheduler.pendingCount, 1, "a poll is armed on launch")
        XCTAssertEqual(scheduler.liveInterval, 30.0)

        scheduler.fireDue()                              // fire the tick (reschedules synchronously)
        XCTAssertEqual(scheduler.pendingCount, 1, "firing the tick re-armed exactly one more")
        XCTAssertEqual(scheduler.liveInterval, 30.0)

        scheduler.fireDue()                              // the loop keeps itself alive
        XCTAssertEqual(scheduler.pendingCount, 1, "each tick re-arms exactly one timer")
          }

          /// A transient fetch failure on a poll keeps the last-known UI (no crash, no
     /// churn, no false error banner).
    func testRefreshSurvivesTransientFailure() async {
        let fake = FakeClient(seed: [AirCon(id: "a", room: "A", on: true, temperature: 21)])
        let c = ACController(client: fake, pollIntervalSeconds: 30, scheduler: ManualIdleScheduler())
          _ = await c.load()
        XCTAssertNil(c.error)

        fake.nextPodsResult = .failure(SensiboError.transport("network blip"))
        await c.refresh()
        XCTAssertEqual(c.acs.first { $0.id == "a" }?.on, true, "a failed poll keeps last-known state")
        XCTAssertNil(c.error, "a transient poll failure must not surface as a UI error banner")
          }
}
