import Foundation

/// Service for handling Sensibo API authentication with the provided key.
public final class AuthService {
    public static let shared = AuthService()
    
    private init() {}
    
    /// Returns the configured API key for authentication.
    public func getAPIKey() -> String {
        return ProcessInfo.processInfo.environment["SENSIBO_API_KEY"] ?? ""
    }
    
    /// Validates if the API key is properly configured.
    public func isApiKeyValid() -> Bool {
        let apiKey = getAPIKey()
        return !apiKey.isEmpty && apiKey.count > 10
    }
}
