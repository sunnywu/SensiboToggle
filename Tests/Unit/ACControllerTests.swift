import XCTest
@testable import SensiboToggle

final class ACControllerTests: XCTestCase {

    func testSetTemperature() async {
        let mockClient = MockSensiboClient(seed: [
            AirCon(id: "test1", room: "Living Room", on: true, temperature: 22.0, mode: "cool")
        ])

        let controller = ACController(client: mockClient)

        // Load the initial data
        await controller.load()

        // Verify initial state
        XCTAssertEqual(controller.acs.count, 1)
        XCTAssertEqual(controller.acs[0].temperature, 22.0)

        // Set temperature
        let task = controller.setTemperature(25.0, for: "test1")

        // Wait for async operation to complete
        await task.value

        // Verify the temperature was updated
        XCTAssertEqual(controller.acs[0].temperature, 25.0)
    }

    func testSetTemperatureToNil() async {
        let mockClient = MockSensiboClient(seed: [
            AirCon(id: "test1", room: "Living Room", on: true, temperature: 22.0, mode: "cool")
        ])

        let controller = ACController(client: mockClient)

        // Load the initial data
        await controller.load()

        // Set temperature to nil
        let task = controller.setTemperature(nil, for: "test1")

        // Wait for async operation to complete
        await task.value

        // Verify the temperature was updated to nil
        XCTAssertNil(controller.acs[0].temperature)
    }
}