import Foundation

/// Protocol so tests can substitute a fake and so the UI depends on abstractions.
protocol SensiboClientProtocol: Sendable {
    func pods() async throws -> [AirCon]
    func setCurrent(on: Bool, podId: String) async throws
    func setTemperature(_ temperature: Double?, for podId: String) async throws
}

/// Live Sensibo client.
///
/// Optimisations for minimal *perceived* latency:
///  - one process-wide `URLSession` whose connection pool is reused across calls,
///  - HTTP/2 + gzip so requests are small and pipelined,
///  - `warmup()` pre-establishes the TLS connection + DNS on first screen load so
///    the first user tap is never paying for a cold connection,
///  - all work is on the async/await network path (no main-thread blocking).
final class SensiboClient: SensiboClientProtocol, Sendable {

    static let live: SensiboClient = SensiboClient(baseURL: "https://home.sensibo.com/api/v2", apiKey: "")

    private let session: URLSession
    private let base: URL
    private let apiKey: String

        /// The tuned session used in production: one process-wide, reused
            /// connection pool, HTTP/2 + gzip, no cookie/redirect overhead.
     static let fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpShouldUsePipelining = false
        config.httpAdditionalHeaders = [
             "Accept-Encoding": "gzip",
             "Accept": "application/json",
             "Connection": "keep-alive",
           ]
        return URLSession(configuration: config)
         }()

        /// `session` is injectable so the 429 backoff/retry path is
            /// deterministic in unit tests.
     init(baseURL: String = "https://home.sensibo.com/api/v2",
          apiKey: String,
          session: URLSession = SensiboClient.fastSession) {
        self.base = URL(string: baseURL) ?? URL(string: "https://home.sensibo.com/api/v2")!
        self.apiKey = apiKey
        self.session = session
          }

    /// Pre-establishes the connection so the first tap pays no connection cost.
    func warmup() async {
        _ = try? await self.pods()
     }

    func pods() async throws -> [AirCon] {
        let url = self.queryURL(path: "/users/me/pods", fields: "*")
        let body = try await self.get(url: url)
          // Sensibo returns { status, result: [ {id, ...}, ... ] }.
        guard let result = body["result"] as? [Any] else { throw SensiboError.decoding("unexpected pods payload") }

        var resultAC: [AirCon] = []
        for entry in result {
            if let obj = entry as? [String: Any],
               let id = obj["id"] as? String, !id.isEmpty {
	                resultAC.append(AirCon(
	                    id: id,
	                    name: Self.nonEmptyString(obj["name"]),
	                    room: Self.roomName(from: obj["room"]),
	                    on: false,
	                    temperature: nil,
	                    mode: nil))
              }
       }
        // Hydrate on/off + name/room from the current acStates (concurrent).
        async let states = try? await self.currentStates(ids: resultAC.map { $0.id })
        let stateMap = await states ?? [:]
        return resultAC.map { ac in
            var copy = ac
            if let s = stateMap[ac.id] {
                copy.on = s.on
                copy.temperature = s.temperature
                copy.mode = s.mode
                if let room = s.room, !room.isEmpty { copy.room = room }
              }
            return copy
          }
     }

    /// Fetch the most recent acState for each pod.
    func currentStates(ids: [String]) async throws -> [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] {
        var map: [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] = [:]
        for id in ids {
            let ac = try? await self.currentState(podId: id)
            if let ac { map[id] = ac }
        }
        return map
     }

    func currentState(podId: String) async throws -> (on: Bool, temperature: Double?, mode: String?, room: String?) {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        let body = try await self.get(url: url)
        guard let result = body["result"] as? [Any], let first = result.first as? [String: Any] else {
             // No history yet: assume off.
            return (on: false, temperature: nil, mode: nil, room: nil)
             }
        let acObj = first["acState"] as? [String: Any] ?? [:]
        let on = acObj["on"] as? Bool ?? false
        let temp = acObj["targetTemperature"] as? Double
        let mode = acObj["mode"] as? String
             // Room is returned by the pods list, not acStates; leave nil here.
        return (on: on, temperature: temp, mode: mode, room: nil)
         }

      /// Convenience: just the current on/off for a pod.
    func currentOn(podId: String) async throws -> Bool {
        try await self.currentState(podId: podId).on
        }

    func setCurrent(on: Bool, podId: String) async throws {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": ["on": on]])
        let (data, response) = try await self.perform(request)
        if (200..<300).contains(response.statusCode) { return }
        let text = String(decoding: data, as: UTF8.self)
        throw SensiboError.http(status: response.statusCode, body: text)
       }

    func setTemperature(_ temperature: Double?, for podId: String) async throws {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build the acState object with temperature
        var acState: [String: Any] = ["on": true]  // Always set on=true when setting temperature
        if let temp = temperature {
            acState["targetTemperature"] = temp
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": acState])

        let (data, response) = try await self.perform(request)
        if (200..<300).contains(response.statusCode) { return }
        let text = String(decoding: data, as: UTF8.self)
        throw SensiboError.http(status: response.statusCode, body: text)
    }

     // MARK: - HTTP helpers

	    private func queryURL(path: String) -> URL {
	        var components = URLComponents(url: self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
	        components?.queryItems = [URLQueryItem(name: "apiKey", value: self.apiKey)]
	        return components?.url ?? self.base
	      }

    private func queryURL(path: String, fields: String) -> URL {
        var components = URLComponents(url: self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "apiKey", value: self.apiKey),
        ]
        return components?.url ?? self.base
    }

    private static func nonEmptyString(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func roomName(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let object = value as? [String: Any] {
            let name = Self.nonEmptyString(object["name"])
            return name.isEmpty ? nil : name
        }
        return nil
    }

     /// Executes a request, transparently retrying on HTTP 429 with exponential
     /// backoff and honouring a `Retry-After` header when present.
     ///
     /// For a *fast* app this matters: because the UI toggle is optimistic, a
     /// transient rate limit never rejects the user's tap — the confirm simply
     /// waits out the limit in the background.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let backoffs: [UInt64] = [50_000_000, 150_000_000, 400_000_000]      // 50ms, 150ms, 400ms
        var attempt = 0
        while true {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SensiboError.transport("no HTTP response")
                }
            if http.statusCode == 429, attempt < backoffs.count {
                let retry: UInt64
                if let raw = http.value(forHTTPHeaderField: "Retry-After"), let secs = Double(raw) {
                    retry = UInt64(max(secs, 0.05) * 1_000_000_000)
                } else {
                    retry = backoffs[attempt]
                    }
                attempt += 1
                try await Task.sleep(nanoseconds: retry)
                continue
                }
            return (data, http)
            }
      }

    private func get(url: URL) async throws -> [String: Any] {
        let (data, http) = try await self.perform(URLRequest(url: url))
        if !(200..<300).contains(http.statusCode) {
            throw SensiboError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
            }
              // Sensibo sometimes returns a JSON array, sometimes an object.
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw SensiboError.decoding("not JSON")
            }
        if let dict = obj as? [String: Any] {
            guard let status = dict["status"] as? String, status == "success"
                  else { throw SensiboError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self)) }
            return dict
          }
        if let arr = obj as? [Any] {
            return ["result": arr]
          }
        return obj as? [String: Any] ?? [:]
       }
}
