import Foundation

/// Core API service for Sensibo air conditioner controller.
/// Implements all requested optimizations: HTTP/2, connection pooling, gzip compression,
/// optimized timeouts, and rate limiting with exponential backoff.

public final class SensiboAPIClient: SensiboClientProtocol, Sendable {
    
    // MARK: - Shared Session Configuration
    
    /// The tuned session used in production for optimal performance:
    /// one process-wide, reused connection pool, HTTP/2 + gzip, no cookie/redirect overhead.
    public static let fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5 // Optimized for faster failure detection
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpShouldUsePipelining = true  // Enable HTTP/2 pipelining
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip",
            "Accept": "application/json",
            "Connection": "keep-alive",
            "User-Agent": "SensiboToggle/1.0",
        ]
        return URLSession(configuration: config)
    }()
    
    // MARK: - Properties
    
    private let session: URLSession
    private let base: URL
    private let apiKey: String
    
    // MARK: - Initialization
    
    public init(baseURL: String = "https://home.sensibo.com/api/v2",
                apiKey: String,
                session: URLSession = SensiboAPIClient.fastSession) {
        self.base = URL(string: baseURL) ?? URL(string: "https://home.sensibo.com/api/v2")!
        self.apiKey = apiKey
        self.session = session
    }
    
    // MARK: - Public Methods
    
    /// Pre-establishes the connection so the first user interaction pays no connection cost.
    public func warmup() async {
        _ = try? await self.pods()
    }
    
    public func pods() async throws -> [AirCon] {
        let url = self.queryURL(path: "/users/me/pods")
        let body = try await self.get(url: url)
        
        // Sensibo returns { status, result: [ {id, ...}, ... ] }.
        guard let result = body["result"] as? [Any] else { 
            throw SensiboError.decoding("unexpected pods payload") 
        }
        
        var resultAC: [AirCon] = []
        for entry in result {
            if let obj = entry as? [String: Any],
               let id = obj["id"] as? String, !id.isEmpty {
                resultAC.append(AirCon(
                    id: id,
                    name: obj["name"] as? String ?? "",
                    room: (obj["room"] as? [String: Any])?["name"] as? String,
                    on: false,
                    temperature: nil,
                    mode: nil))
            }
        }
        
        // Hydrate on/off + name/room from the current acStates (concurrent).
        let states = try await self.currentStates(ids: resultAC.map { $0.id })
        let stateMap = states
        
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
    
    public func currentStates(ids: [String]) async throws -> [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] {
        var map: [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] = [:]
        
        // Fetch all states concurrently with a limit of 5 to prevent overwhelming the network
        let semaphore = DispatchSemaphore(value: 5)
        let group = DispatchGroup()
        
        let tasks = ids.map { id in
            return Task {
                semaphore.wait()
                defer { semaphore.signal() }
                
                do {
                    let currentState = try await self.currentState(podId: id)
                    await MainActor.run {
                        map[id] = currentState
                    }
                } catch {
                    // Log error but don't throw - continue with other requests
                    print("Error fetching state for pod \(id): \(error)")
                }
            }
        }
        
        _ = await withThrowingTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    try await task.value
                }
            }
            try await group.waitForAll()
        }
        
        return map
    }
    
    public func currentState(podId: String) async throws -> (on: Bool, temperature: Double?, mode: String?, room: String?) {
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
    
    public func setCurrent(on: Bool, podId: String) async throws {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": ["on": on]])
        
        // Reduced timeout for better perceived latency 
        request.timeoutInterval = 5
        
        let (data, response) = try await self.perform(request)
        
        if (200..<300).contains(response.statusCode) { return }
        
        let text = String(decoding: data, as: UTF8.self)
        throw SensiboError.http(status: response.statusCode, body: text)
    }
    
    public func setTemperature(_ temperature: Double?, for podId: String) async throws {
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
        
        // Reduced timeout for better perceived latency
        request.timeoutInterval = 5
        
        let (data, response) = try await self.perform(request)
        
        if (200..<300).contains(response.statusCode) { return }
        
        let text = String(decoding: data, as: UTF8.self)
        throw SensiboError.http(status: response.statusCode, body: text)
    }
    
    // MARK: - HTTP Helpers
    
    private func queryURL(path: String) -> URL {
        var components = URLComponents(url: self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "apiKey", value: self.apiKey)]
        return components?.url ?? self.base
    }
    
    /// Executes a request with optimized rate limiting and exponential backoff.
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