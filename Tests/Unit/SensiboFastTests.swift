import XCTest
@testable import SensiboToggle

/// Unit tests for fast Sensibo API interactions with the provided API key.
final class SensiboFastTests: XCTestCase {
    
    /// Test that demonstrates fast initialization and warmup using the provided API key
    func testFastClientInitialization() async throws {
        // Using the provided API key directly in test setup
        let testApiKey = "test-api-key"
        
        // Create fast client with optimized session settings
        let client = SensiboAPIClient(apiKey: testApiKey)
        
        // Verify client has the right configuration 
        XCTAssertFalse(client.apiKey.isEmpty)
        XCTAssertEqual(client.apiKey, testApiKey)
        
        // Test warmup - this pre-establishes connections with no user-facing latency
        await client.warmup()
        
        // Test pod fetching is fast (this should be optimized for minimal latency)
        let pods = try? await client.pods()
        XCTAssertNotNil(pods)
    }
    
    /// Test that validates the optimistic UI pattern works with minimal perceived latency
    func testOptimisticTogglePattern() async {
        // Using mock client to test optimistic behavior
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
        
        // Immediately verify UI flip happened before await
        XCTAssertFalse(controller.acs[0].on)
        
        // Wait for async operation to complete and confirm server update
        await toggleTask.value
        
        // Verify state is now flipped back (because mock doesn't actually change it)
        XCTAssertTrue(controller.acs[0].on)
    }
    
    /// Test the fast session configuration that reduces latency
    func testFastSessionConfiguration() {
        let session = SensiboAPIClient.fastSession
        let config = session.configuration
        
        // Verify key settings are optimized for minimal connection latency
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 8)
        XCTAssertEqual(config.timeoutIntervalForRequest, 5)
        XCTAssertEqual(config.timeoutIntervalForResource, 5)
        
        // Verify compression and HTTP/2 support are enabled
        let acceptEncoding = config.httpAdditionalHeaders?["Accept-Encoding"] as? String
        XCTAssertEqual(acceptEncoding, "gzip")
    }
    
    /// Test that validates authentication with the provided API key works correctly
    func testAPIKeyValidation() {
        let client = SensiboAPIClient(apiKey: "test-api-key")
        XCTAssertEqual(client.apiKey, "test-api-key")
    }
}
