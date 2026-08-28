import XCTest
@testable import SensiboToggle

@MainActor
final class FakeTapoClient: TapoClientProtocol {
    var nextLoad: Result<[Light], Error>
    var failSet = false
    private(set) var recordedSets: [String] = []

    init(seed: [Light]) {
        self.nextLoad = .success(seed)
    }

    func load() async throws -> [Light] {
        switch nextLoad {
        case .success(let lights): return lights
        case .failure(let error): throw error
        }
    }

    func set(on: Bool, device: String) async throws {
        recordedSets.append("\(on)/\(device)")
        if failSet {
            throw TapoError.transport("boom")
        }
    }

    func status(device: String) async throws -> Bool {
        false
    }
}

@MainActor
final class TapoControllerTests: XCTestCase {
    func testLightToggleIsOptimisticImmediately() async {
        let fake = FakeTapoClient(seed: [
            Light(id: "Verandah", name: "Verandah", room: nil, on: false),
        ])
        let controller = TapoController(client: fake)
        _ = await controller.load()

        let task = controller.toggle("Verandah")

        XCTAssertEqual(controller.lights.first?.on, true)
        XCTAssertTrue(controller.pending.contains("Verandah"))

        await task.value
        XCTAssertEqual(fake.recordedSets, ["true/Verandah"])
        XCTAssertTrue(controller.pending.isEmpty)
    }

    func testLightToggleRevertsOnFailure() async {
        let fake = FakeTapoClient(seed: [
            Light(id: "Verandah", name: "Verandah", room: nil, on: true),
        ])
        fake.failSet = true
        let controller = TapoController(client: fake)
        _ = await controller.load()

        let task = controller.toggle("Verandah")
        await task.value

        XCTAssertEqual(controller.lights.first?.on, true)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.pending.isEmpty)
    }
}
