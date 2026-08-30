import Foundation

// MARK: - The TfNSW "rapidJSON" transport + parsing.
//
// Mirrors `SensiboClient`'s style: a `Sendable` final class over a reused
// `URLSession`, decoding with `JSONSerialization` (no Codable), and a protocol so
// the UI + controller depend on an abstraction and tests can substitute a mock.
//
// Two endpoints:
//    - `stop_finder`     → resolves "Ashfield" to a TfNSW stop id (once, at startup)
//    - `departure_mon`    → the live/upcoming departure board (polled each minute)
//
// Auth is a *custom* scheme — `Authorization: apikey <key>` — not `Bearer` (which 401s).

protocol NSWTrainClientProtocol: Sendable {
       /// Resolve `name` (e.g. "Ashfield") to a TfNSW stop id. Returns the best stop.
     func resolveStopID(name: String) async throws -> String
       /// The raw, *train-only* upcoming departures at `stopID` (all destinations; the
       /// controller does the city-bound matching).
     func departures(stopID: String) async throws -> [NSWTrainArrival]
}

// MARK: - Errors

enum NSWTrainError: Error, Equatable {
    case transport(String)
    case http(status: Int)
    case noStop    // a station lookup returned no usable location
    case decoding(String)

    var localizedDescription: String {
        switch self {
        case .transport(let message):
            return "Train times unavailable (network: \(message))."
        case .http(let status):
            return "Train times unavailable (HTTP \(status))."
        case .noStop:
            return "Train times unavailable (station not found)."
        case .decoding(let message):
            return "Train times unavailable (bad data: \(message))."
         }
      }
}

// MARK: - Live client

final class NSWTrainClient: NSWTrainClientProtocol, Sendable {

    static let live: NSWTrainClient = NSWTrainClient(baseURL: "https://api.transport.nsw.gov.au/v1/tp", apiKey: "")

    private let session: URLSession
    private let base: URL
    private let apiKey: String

     static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
          }()

    init(baseURL: String = "https://api.transport.nsw.gov.au/v1/tp",
         apiKey: String,
         session: URLSession = NSWTrainClient.session) {
        self.base = URL(string: baseURL) ?? URL(string: "https://api.transport.nsw.gov.au/v1/tp")!
        self.apiKey = apiKey
        self.session = session
          }

     // MARK: stop_finder → id

    func resolveStopID(name: String) async throws -> String {
        let url = self.queryURL(path: "/stop_finder", query: [
            ("name_sf", name),
            ("type", "stop"),
         ])
        let obj = try await self.getJSON(url: url)
        guard let locations = obj["locations"] as? [Any] else { throw NSWTrainError.noStop }
        // Prefer the "best" match the API flags, else fall back to the first stop entry.
        for entry in locations {
            guard let loc = entry as? [String: Any],
                  let type = loc["type"] as? String, type == "stop",
                  let id = loc["id"] as? String, !id.isEmpty
            else { continue }
            if (loc["isBest"] as? Bool) ?? false { return id }
        }
        if let first = locations.first(where: { ($0 as? [String: Any])?["type"] as? String == "stop" }) as? [String: Any],
           let id = first["id"] as? String, !id.isEmpty {
            return id
          }
        throw NSWTrainError.noStop
          }

       // MARK: departure_mon → train-only arrivals

    func departures(stopID: String) async throws -> [NSWTrainArrival] {
        let now = Date()
        let query = [
             ("outputFormat", "rapidJSON"),
             ("coordOutputFormat", "EPSG:4326"),
             ("mode", "direct"),
             ("type_dm", "stop"),
             ("name_dm", stopID),
             ("depArrMacro", "dep"),
             ("itdDate", Self.itdDate(now)),
             ("itdTime", Self.itdTime(now)),
             ("TfNSWDM", "true"),
          ]
        let url = self.queryURL(path: "/departure_mon", query: query)
        let obj = try await self.getJSON(url: url)
        return Self.parseDepartures(obj)
            }

              /// Parse a rapidJSON `stopEvents` payload into train-only arrivals. Kept as a
            /// pure static so it can be unit-tested against a captured response with no network.
        static func parseDepartures(_ obj: [String: Any]) -> [NSWTrainArrival] {
        guard let events = obj["stopEvents"] as? [Any] else { return [] }
        var arrivals: [NSWTrainArrival] = []
        for entry in events {
            guard let event = entry as? [String: Any] else { continue }
            guard let transportation = event["transportation"] as? [String: Any] else { continue }
                 // Trains only: product.class == 1 (skip the buses / other modes on the board).
            let productClass = (transportation["product"] as? [String: Any])?["class"] as? Int
            if productClass != NSWTrainSelection.trainProductClass { continue }
                 // Best known time: real-time estimate when present, else the schedule.
            guard let departure = Self.readDeparture(event) else { continue }
                 // Skip entries whose destination we can't display.
            let destination = Self.readDestination(transportation)
            guard !destination.isEmpty else { continue }
            arrivals.append(NSWTrainArrival(destination: destination, departure: departure))
           }
        return arrivals
           }

       // MARK: parsing

    private static func readDeparture(_ event: [String: Any]) -> Date? {
        if let estimated = event["departureTimeEstimated"] as? String, let date = Self.parseTimestamp(estimated) {
             return date
           }
        guard let planned = event["departureTimePlanned"] as? String else { return nil }
        return Self.parseTimestamp(planned)
          }

    private static func readDestination(_ transportation: [String: Any]) -> String {
        guard let destination = transportation["destination"] as? [String: Any] else { return "" }
        return (destination["name"] as? String).map { $0.isEmpty ? "" : $0 } ?? ""
          }

       /// ISO-8601 with a trailing "Z" (UTC), e.g. "2026-08-30T06:32:00Z". A fresh
    /// formatter per call — `ISO8601DateFormatter` is not safe to share across tasks.
     private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
          // Fallback for a bare "yyyy-MM-dd'T'HH:mm:ss'Z'" shape.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(identifier: "UTC")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fallback.date(from: raw)
           }

      /// `itdDate`/`itdTime` are the query params that anchor "now" in device-local time.
     private static func itdDate(_ date: Date) -> String {
        String(format: "%04d%02d%02d",
             Calendar.current.component(.year, from: date),
             Calendar.current.component(.month, from: date),
             Calendar.current.component(.day, from: date))
      }

     private static func itdTime(_ date: Date) -> String {
        String(format: "%02d%02d",
             Calendar.current.component(.hour, from: date),
             Calendar.current.component(.minute, from: date))
          }

       // MARK: HTTP plumbing

    private func queryURL(path: String, query: [ (name: String, value: String)]) -> URL {
        var components = URLComponents(url: self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        return components?.url ?? self.base
          }

       /// GET with the custom `Authorization: apikey <key>` header; returns the decoded object.
     private func getJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !self.apiKey.isEmpty {
             request.setValue("apikey \(self.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSWTrainError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw NSWTrainError.http(status: http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSWTrainError.decoding("not JSON")
           }
        return obj
          }
}

// MARK: - Mock client (hermetic UI + hermetic controller)

/// A seeded in-memory `NSWTrainClientProtocol` double. Mirrors `MockSensiboClient`:
/// `@MainActor`, single-threaded, `Sendable`, zero network.
@MainActor
final class MockNSWTrainClient: NSWTrainClientProtocol {
    private let stopID: String
    private let seed: [NSWTrainArrival]
      /// Number of the next polling requests that should throw, for driving the
     /// "keep the last good value" / stale paths.
     private var outstandingFailures: Int = 0

    init(resolvedStopID: String = NSWTrainConfig.ashfieldStopID, seed: [NSWTrainArrival]) {
        self.stopID = resolvedStopID
        self.seed = seed
      }

    func resolveStopID(name: String) async throws -> String {
        self.stopID
      }

       /// Make the next `count` poll(s) throw (simulating a transient network outage).
    func failNextCount(_ count: Int) {
        self.outstandingFailures = max(count, self.outstandingFailures)
      }

    func departures(stopID: String) async throws -> [NSWTrainArrival] {
        if self.outstandingFailures > 0 {
            self.outstandingFailures -= 1
            throw NSWTrainError.transport("simulated outage")
          }
        return self.seed
      }
}
