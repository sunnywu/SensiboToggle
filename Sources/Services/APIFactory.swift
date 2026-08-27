import Foundation

/// Factory for creating Sensibo API clients with proper configuration.
public final class APIFactory {
    /// Creates a production-ready Sensibo API client with optimizations.
    public static func makeProductionClient() -> SensiboAPIClient {
        let apiKey = AuthService.shared.getAPIKey()
        return SensiboAPIClient(apiKey: apiKey)
    }
    
    /// Creates a testable Sensibo API client for unit testing.
    public static func makeTestClient(session: URLSession = SensiboAPIClient.fastSession) -> SensiboAPIClient {
        return SensiboAPIClient(apiKey: "test-api-key", session: session)
    }
}