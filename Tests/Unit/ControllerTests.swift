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
