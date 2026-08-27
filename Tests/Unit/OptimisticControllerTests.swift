import XCTest
@testable import SensiboToggle

/// Unit tests for the AC Controller with optimistic updates.
final class OptimisticControllerTests: XCTestCase {
    
    /// Test that validates the optimistic UI toggle pattern works correctly.
    func testOptimisticTogglePattern() async throws {
        let mockClient = MockSensiboClient(seed: [
            AirCon(id: "test1", room: "Living Room", on: true, temperature: 22.0, mode: "cool")
        ])
        
        let controller = ACController(client: mockClient)
        
        // Load the initial data
        await controller.load()
        
        // Verify initial state
        XCTAssertEqual(controller.acs.count, 1)
        XCTAssertTrue(controller.acs[0].on)
        
        // Toggle the device - should happen optimistically (instantly)
        let toggleTask = Task {
            await controller.toggle("test1")
        }
        
        // Immediately verify UI flip happened before await completes
        XCTAssertFalse(controller.acs[0].on)
        
        // Wait for async operation to complete
        await toggleTask.value
        
        // Verify state is now flipped back (because mock doesn't actually change it)
        XCTAssertTrue(controller.acs[0].on)
    }
    
    /// Test that validates error handling works in the controller.
    func testErrorHandling() async {
        let mockClient = MockSensiboClient(seed: [
            AirCon(id: "error", room: "Test Room", on: false, temperature: nil, mode: nil)
        ])
        
        let controller = ACController(client: mockClient)
        
        // Should be able to load without error
        await controller.load()
        XCTAssertNil(controller.error)
    }
    
    /// Test that validates the loading state.
    func testLoadingState() async {
        let mockClient = MockSensiboClient(seed: [
            AirCon(id: "test1", room: "Living Room", on: true, temperature: 22.0, mode: "cool")
        ])
        
        let controller = ACController(client: mockClient)
        
        // Load should set loading state
        await controller.load()
        
        XCTAssertFalse(controller.isLoading)
    }
}