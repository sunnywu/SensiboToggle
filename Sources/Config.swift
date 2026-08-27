import Foundation

enum SensiboError: Error, LocalizedError, Equatable {
    case noApikey
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noApikey:
            return "No API key configured."
        case let .http(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        case let .decoding(message):
            return "Bad response: \(message)"
        case let .transport(message):
            return "Network: \(message)"
          }
      }
}

/// How configuration is resolved.
///
/// `mock`  -> no I/O, no key. The service is backed by an in-memory double so the
///            UI can be exercised (and exercised by XCUITest) with zero latency.
/// `live`  -> read apiKey from `config/local.config.json` in the bundle (shipped at
///            build time). A real call to Sensibo happens on every launch.
enum ConfigMode {
    case live
    case mock
}

struct AppConfig: Equatable {
    var apiKey: String
    var baseURL: String
    var mockMode: Bool
}

enum Config {
    /// Re-reads the environment each call, so it is testable and deterministic.
    static func load() -> AppConfig {
        let env = ProcessInfo.processInfo.environment

          // Forced mock (used by XCUITest so it never pings the real device).
        if env["SENSIBO_MOCK"] == "1" {
            return AppConfig(apiKey: "", baseURL: "https://home.sensibo.com/api/v2", mockMode: true)
          }

        if let key = env["SENSIBO_API_KEY"], !key.isEmpty {
            let base = env["SENSIBO_BASE_URL"] ?? "https://home.sensibo.com/api/v2"
            return AppConfig(apiKey: key, baseURL: base, mockMode: false)
          }

        if let url = Bundle.main.url(forResource: "local", withExtension: "config.json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let key = (obj["apiKey"] as? String) ?? ""
            let base = (obj["baseURL"] as? String) ?? "https://home.sensibo.com/api/v2"
            let mock = (obj["mockMode"] as? Bool) ?? false
            return AppConfig(apiKey: key, baseURL: base, mockMode: mock)
          }

        return AppConfig(apiKey: "", baseURL: "https://home.sensibo.com/api/v2", mockMode: false)
       }
}
