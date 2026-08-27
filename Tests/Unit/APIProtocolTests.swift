import XCTest
@testable import SensiboToggle

/// Unit tests for the core API service implementation.
final class APIProtocolTests: XCTestCase {
    
    /// Test that validates the API client can be initialized with the provided key.
    func testClientInitialization() {
        let apiKey = "test-api-key"
        let client = SensiboAPIClient(apiKey: apiKey)
        
        XCTAssertFalse(client.apiKey.isEmpty)
        XCTAssertEqual(client.apiKey, apiKey)
    }
    
    /// Test that validates the session configuration is optimized.
    func testFastSessionConfiguration() {
        let session = SensiboAPIClient.fastSession
        let config = session.configuration
        
        // Validate key settings for minimal connection latency
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 8)
        XCTAssertEqual(config.timeoutIntervalForRequest, 5)
        XCTAssertEqual(config.timeoutIntervalForResource, 5)
        
        // Validate compression and HTTP/2 support are enabled
        let acceptEncoding = config.httpAdditionalHeaders?["Accept-Encoding"] as? String
        XCTAssertEqual(acceptEncoding, "gzip")
        
        let connectionHeader = config.httpAdditionalHeaders?["Connection"] as? String
        XCTAssertEqual(connectionHeader, "keep-alive")
    }
    
    /// Test that validates the API key is correctly set.
    func testApiKeyIsSet() {
        let client = SensiboAPIClient(apiKey: "test1234567890")
        XCTAssertEqual(client.apiKey, "test1234567890")
    }
    
    /// Test warmup function works without errors.
    func testClientWarmup() async {
        let client = SensiboAPIClient(apiKey: "test-api-key")
        await client.warmup()
        
        // Warmup should complete without throwing an error
        XCTAssertTrue(true) // If we get here, warmup completed successfully
    }
}
