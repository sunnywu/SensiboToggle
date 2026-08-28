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
/// `mock`   -\u003e no I/O, no key. The service is backed by an in-memory double so the
///            UI can be exercised (and exercised by XCUITest) with zero latency.
/// `live`   -\u003e read apiKey from `config/local.config.json` in the bundle (shipped at
///            build time). A real call to Sensibo happens on every launch.
enum ConfigMode {
    case live
    case mock
}

struct AppConfig: Equatable {
    var apiKey: String
    var baseURL: String
    var mockMode: Bool
       // Tapo (Verandah light) credentials. Defaulted so the Sensibo-only paths and
       // every existing `AppConfig(...)` call site keep compiling unchanged.
    var tapoEmail: String = ""
    var tapoPassword: String = ""
    var tapoDevices: [TapoDeviceConfig] = []
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
            return Self.appConfig(from: obj, environment: env)
            }

        return AppConfig(apiKey: "", baseURL: "https://home.sensibo.com/api/v2", mockMode: false)
         }

    static func appConfig(from obj: [String: Any],
                          environment env: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        let key = (obj["apiKey"] as? String) ?? ""
        let base = (obj["baseURL"] as? String) ?? "https://home.sensibo.com/api/v2"
        let mock = (obj["mockMode"] as? Bool) ?? false
        let tapo = obj["tapo"] as? [String: Any]

        let tapoEmail = env["TAPO_EMAIL"] ?? (tapo?["email"] as? String) ?? ""
        let tapoPassword = env["TAPO_PASSWORD"] ?? (tapo?["password"] as? String) ?? ""
        let tapoDevices = Self.parseTapoDevices(tapo?["devices"], environment: env)

        return AppConfig(apiKey: key,
                         baseURL: base,
                         mockMode: mock,
                         tapoEmail: tapoEmail,
                         tapoPassword: tapoPassword,
                         tapoDevices: tapoDevices)
     }

       /// Parse the `tapo.devices` array into `[TapoDeviceConfig]`. Tolerant of
       /// missing fields so a half-filled config still loads (with a blank IP).
    private static func parseTapoDevices(_ raw: Any?, environment env: [String: String]) -> [TapoDeviceConfig] {
        if let ip = env["TAPO_DEVICE_IP"], !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [
                TapoDeviceConfig(
                    name: env["TAPO_DEVICE_NAME"] ?? "Tapo Light",
                    ip: ip,
                    type: env["TAPO_DEVICE_TYPE"]
                )
            ]
        }

        guard let array = raw as? [[String: Any]] else { return [] }
        var out: [TapoDeviceConfig] = []
        for entry in array {
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let ip = (entry["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = (entry["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(TapoDeviceConfig(name: name, ip: ip, type: type))
            }
        return out
         }
}
