import AppIntents
import Foundation
import WidgetKit

let bedroomOneWidgetKind = "BedroomOneToggleWidget"

struct WidgetConfig: Sendable {
    var apiKey: String
    var baseURL: String
    var mockMode: Bool
}

enum WidgetConfigLoader {
    static func load() -> WidgetConfig {
        let env = ProcessInfo.processInfo.environment
        if env["SENSIBO_MOCK"] == "1" {
            return WidgetConfig(apiKey: "", baseURL: fallbackBaseURL, mockMode: true)
        }
        if let key = env["SENSIBO_API_KEY"], !key.isEmpty {
            return WidgetConfig(apiKey: key, baseURL: env["SENSIBO_BASE_URL"] ?? fallbackBaseURL, mockMode: false)
        }
        if let url = Bundle.main.url(forResource: "local", withExtension: "config.json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return WidgetConfig(
                apiKey: object["apiKey"] as? String ?? "",
                baseURL: object["baseURL"] as? String ?? fallbackBaseURL,
                mockMode: object["mockMode"] as? Bool ?? false
            )
        }
        return WidgetConfig(apiKey: "", baseURL: fallbackBaseURL, mockMode: false)
    }

    private static let fallbackBaseURL = "https://home.sensibo.com/api/v2"
}

struct BedroomOneState: Equatable, Sendable {
    var isOn: Bool?
    var temperature: Double?
    var error: String?

    static let loading = BedroomOneState(isOn: nil, temperature: nil, error: nil)
}

struct ToggleBedroomOneIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Bedroom 1"
    static let description = IntentDescription("Turns the Bedroom 1 air conditioner on if it is off, and off if it is on.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let config = WidgetConfigLoader.load()
        guard !config.mockMode else {
            WidgetCenter.shared.reloadTimelines(ofKind: bedroomOneWidgetKind)
            return .result()
        }
        _ = try await BedroomOneSensiboClient(config: config).toggleBedroomOne()
        WidgetCenter.shared.reloadTimelines(ofKind: bedroomOneWidgetKind)
        return .result()
    }
}

final class BedroomOneSensiboClient: @unchecked Sendable {
    private struct Pod {
        var id: String
        var displayName: String
    }

    private static let bedroomName = "Bedroom 1"
    private static let cachedPodIdKey = "bedroomOneWidget.podId"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "Connection": "keep-alive",
        ]
        return URLSession(configuration: config)
    }()

    private let config: WidgetConfig
    private let baseURL: URL

    init(config: WidgetConfig) {
        self.config = config
        self.baseURL = URL(string: config.baseURL) ?? URL(string: "https://home.sensibo.com/api/v2")!
    }

    func bedroomOneState() async throws -> BedroomOneState {
        let podId = try await bedroomOnePodId()
        let state = try await currentState(podId: podId)
        return BedroomOneState(isOn: state.isOn, temperature: state.temperature, error: nil)
    }

    func toggleBedroomOne() async throws -> Bool {
        do {
            let podId = try await bedroomOnePodId()
            let state = try await currentState(podId: podId)
            let newValue = !state.isOn
            try await setCurrent(on: newValue, podId: podId)
            return newValue
        } catch {
            Self.clearCachedPodId()
            let podId = try await resolveBedroomOnePodId()
            let state = try await currentState(podId: podId)
            let newValue = !state.isOn
            try await setCurrent(on: newValue, podId: podId)
            return newValue
        }
    }

    private func bedroomOnePodId() async throws -> String {
        if let podId = Self.cachedPodId {
            return podId
        }
        return try await resolveBedroomOnePodId()
    }

    private func resolveBedroomOnePodId() async throws -> String {
        let pods = try await pods()
        guard let pod = pods.first(where: { $0.displayName.caseInsensitiveCompare(Self.bedroomName) == .orderedSame }) else {
            throw WidgetSensiboError.bedroomNotFound
        }
        Self.cachedPodId = pod.id
        return pod.id
    }

    private func pods() async throws -> [Pod] {
        let body = try await get(path: "/users/me/pods", queryItems: [URLQueryItem(name: "fields", value: "*")])
        guard let result = body["result"] as? [Any] else {
            throw WidgetSensiboError.badResponse
        }
        return result.compactMap { item in
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String,
                  !id.isEmpty else {
                return nil
            }
            return Pod(id: id, displayName: Self.displayName(from: object))
        }
    }

    private func currentState(podId: String) async throws -> (isOn: Bool, temperature: Double?) {
        let body = try await get(path: "/pods/\(podId)/acStates")
        guard let result = body["result"] as? [Any],
              let first = result.first as? [String: Any],
              let acState = first["acState"] as? [String: Any] else {
            return (false, nil)
        }
        return (acState["on"] as? Bool ?? false, acState["targetTemperature"] as? Double)
    }

    private func setCurrent(on: Bool, podId: String) async throws {
        guard !config.apiKey.isEmpty else {
            throw WidgetSensiboError.missingAPIKey
        }
        var request = URLRequest(url: url(path: "/pods/\(podId)/acStates"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": ["on": on]])

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WidgetSensiboError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WidgetSensiboError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    private func get(path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard !config.apiKey.isEmpty else {
            throw WidgetSensiboError.missingAPIKey
        }
        let (data, response) = try await Self.session.data(from: url(path: path, queryItems: queryItems))
        guard let http = response as? HTTPURLResponse else {
            throw WidgetSensiboError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WidgetSensiboError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "success" else {
            throw WidgetSensiboError.badResponse
        }
        return object
    }

    private func url(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems + [URLQueryItem(name: "apiKey", value: config.apiKey)]
        return components?.url ?? baseURL
    }

    private static var cachedPodId: String? {
        get { UserDefaults.standard.string(forKey: cachedPodIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: cachedPodIdKey) }
    }

    private static func clearCachedPodId() {
        UserDefaults.standard.removeObject(forKey: cachedPodIdKey)
    }

    private static func displayName(from object: [String: Any]) -> String {
        if let room = object["room"] as? [String: Any],
           let name = clean(room["name"]),
           !name.isEmpty {
            return name
        }
        if let room = object["room"] as? String,
           let name = clean(room),
           !name.isEmpty {
            return name
        }
        if let name = clean(object["name"]),
           !name.isEmpty {
            return name
        }
        return ""
    }

    private static func clean(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WidgetSensiboError: Error {
    case badResponse
    case bedroomNotFound
    case http(Int, String)
    case missingAPIKey
}
