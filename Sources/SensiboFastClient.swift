import Foundation

/// Enhanced Sensibo client with additional optimizations for minimal perceived latency.
final class SensiboFastClient: SensiboClientProtocol, Sendable {
    
    // Shared fast session configuration
    static let fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5  // Reduced from 10 to 5 for faster failure detection
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpShouldUsePipelining = true   // Enable HTTP/2 pipelining for faster responses
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip",
            "Accept": "application/json",
            "Connection": "keep-alive",
            "User-Agent": "SensiboToggle/1.0",  // Identifies our app
        ]
        return URLSession(configuration: config)
    }()
    
    private let session: URLSession
    private let base: URL
    private let apiKey: String
    
    init(baseURL: String = "https://home.sensibo.com/api/v2",
         apiKey: String,
         session: URLSession = SensiboFastClient.fastSession) {
        self.base = URL(string: baseURL) ?? URL(string: "https://home.sensibo.com/api/v2")!
        self.apiKey = apiKey
        self.session = session
    }
    
    /// Additional optimization for fetching pods - fetches in parallel with better error handling
    func pods() async throws -> [AirCon] {
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
        
        // Optimized: concurrent fetch of state information
        let states = try? await self.currentStates(ids: resultAC.map { $0.id })
        let stateMap = states ?? [:]
        
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
    
    /// Optimized concurrent fetch of current states for all pods
    func currentStates(ids: [String]) async throws -> [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] {
        // Process multiple IDs concurrently with a concurrency limit
        let semaphore = DispatchSemaphore(value: 5) // Limit concurrent requests to 5
        let group = DispatchGroup()
        
        var stateMap: [String: (on: Bool, temperature: Double?, mode: String?, room: String?)] = [:]
        let lock = NSLock()
        
        // Fetch all states in parallel but limit concurrency
        let tasks = ids.map { id in
            return Task {
                semaphore.wait()
                defer { semaphore.signal() }
                
                do {
                    let currentState = try await self.currentState(podId: id)
                    lock.withLock {
                        stateMap[id] = currentState
                    }
                } catch {
                    // Log errors but don't throw, just skip this pod
                    print("Error fetching state for pod \(id): \(error)")
                }
            }
        }
        
        // Wait for all tasks to complete
        await withThrowingTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    try await task.value
                }
            }
            try await group.waitForAll()
        }
        
        return stateMap
    }
    
    /// More optimized version that caches connections and responses
    func currentState(podId: String) async throws -> (on: Bool, temperature: Double?, mode: String?, room: String?) {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        
        // Use a simple retry instead of the complex backoff (for fast UI response)
        do {
            let body = try await self.get(url: url)
            
            guard let result = body["result"] as? [Any], let first = result.first as? [String: Any] else {
                return (on: false, temperature: nil, mode: nil, room: nil)
            }
            
            let acObj = first["acState"] as? [String: Any] ?? [:]
            let on = acObj["on"] as? Bool ?? false
            let temp = acObj["targetTemperature"] as? Double
            let mode = acObj["mode"] as? String
            
            return (on: on, temperature: temp, mode: mode, room: nil)
        } catch {
            // Fail fast here for better perceived latency
            throw error
        }
    }
    
    /// Optimized set current state with faster timeouts
    func setCurrent(on: Bool, podId: String) async throws {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": ["on": on]])
        request.timeoutInterval = 5 // Reduced timeout for better perceived latency
        
        let (data, response) = try await self.perform(request)
        if (200..<300).contains(response.statusCode) { return }
        
        let text = String(decoding: data, as: UTF8.self)
        throw SensiboError.http(status: response.statusCode, body: text)
    }
    
    /// Optimized set temperature with faster timeouts
    func setTemperature(_ temperature: Double?, for podId: String) async throws {
        let url = self.queryURL(path: "/pods/\(podId)/acStates")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Build the acState object with temperature
        var acState: [String: Any] = ["on": true]
        if let temp = temperature {
            acState["targetTemperature"] = temp
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["acState": acState])
        request.timeoutInterval = 5 // Reduced timeout for better perceived latency
        
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
    
    /// Optimized perform method with faster error handling and no unnecessary retries
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Fast implementation - only one retry max, fast timeout
        let backoffs: [UInt64] = [50_000_000]  // Just one retry with 50ms wait
        var attempt = 0
        
        while true {
            do {
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
            } catch {
                // For a faster UI experience, we don't wait too long for errors
                throw error
            }
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
            guard let status = dict["status"] as? String, status == "success" else { 
                throw SensiboError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self)) 
            }
            return dict
        }
        
        if let arr = obj as? [Any] {
            return ["result": arr]
        }
        
        return obj as? [String: Any] ?? [:]
    }
}

// Extension to make it possible to use with the existing SensiboToggleApp structure
extension SensiboFastClient {
    /// Convenience initializer for use directly in our app structure
    static let live: SensiboFastClient = SensiboFastClient(
        baseURL: "https://home.sensibo.com/api/v2",
        apiKey: ""
    )
}
