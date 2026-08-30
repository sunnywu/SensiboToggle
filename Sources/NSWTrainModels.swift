import Foundation

// MARK: - The next-train arrival banner (Ashfield → Wynyard)
//
// A glanceable banner, pinned at the bottom of the screen on the iOS app and as a
// section in the menu-bar app, that shows the **next up-to-2 trains from
// Ashfield that pass Wynyard**: service destination, local departure time, and
// minutes-until.
//
// The model is deliberately *IO-free*: an `NSWTrainArrival` is just a destination +
// an absolute departure `Date`, so every matching / selection / formatting / state
// decision lives in pure, hermetically-testable functions. The transport + parsing
// live in `NSWTrainClient.swift`; the polling + state machine live in
// `NSWTrainController.swift`.

/// One departure from Ashfield that we might show. `departure` is the *best-known*
/// time — the real-time `departureTimeEstimated` when the feed provides one, else
/// the scheduled `departureTimePlanned` — already normalized to absolute time.
struct NSWTrainArrival: Equatable, Hashable, Sendable {
    let destination: String
    let departure: Date
}

/// A pre-formatted banner row, ready to render. Built once per poll by the controller
/// so the displayed "in N min" stays stable between polls (the value does not tick live,
/// by design — "refresh each poll, no live second-tick").
struct NSWTrainDisplayRow: Equatable, Sendable {
    let destination: String     // e.g. "Wynyard"
    let clockText: String       // e.g. "14:05" (device local time)
    let minutesText: String     // "in 7 min" or "now"
    let minutes: Int

     /// Compact leading text for glanceable rows: "7 min" rather than "in 7 min".
    var leadMinutesText: String {
        self.minutesText.hasPrefix("in ") ? String(self.minutesText.dropFirst(3)) : self.minutesText
    }

     /// `true` when the train is close enough to warrant amber emphasis.
    var isImminent: Bool { self.minutes <= 5 }

     /// Fallback plain-text form: "7 min 🚃 Wynyard 14:05".
    var text: String { "\(self.leadMinutesText) 🚃 \(self.destination) \(self.clockText)" }
}

/// The banner's full state, mirrored into the views. `.hidden` (disabled or no key)
/// means the view renders nothing at all.
enum NSWTrainState: Equatable, Sendable {
    case hidden                       // disabled / no key
    case loading                      // first poll in flight, no data yet
    case next([NSWTrainDisplayRow])   // up to two matching trains
    case empty                        // polls succeed but no matching train in the window
    case stale                        // last good value too old (> staleAfter) → "unavailable"
}

/// User-tunable configuration for the banner.
///
/// Every field has a default so the type is cheap to construct and so existing
/// `AppConfig` call sites keep compiling when this is added (mirrors how the tapo /
/// wallPanel config hangs off `AppConfig` with defaults).
struct NSWTrainConfig: Equatable, Sendable {
    var apiKey: String
    var enabled: Bool
    var originStation: String
    var stopID: String                       // non-empty → skip the stop_finder lookup
    var destinationStation: String
    var destinationStopID: String            // non-empty → query Ashfield → destination directly
    var destinationAllowlist: [String]
    var pollIntervalSeconds: Double
    var staleAfterSeconds: Double

    /// Backwards-compatible fallback only. The live path uses `destinationStopID` and
    /// asks TfNSW for journeys from Ashfield to Wynyard directly.
    static let defaultDestinationAllowlist = [
        "Wynyard",
        "Central",
        "Town Hall",
        "Circular Quay",
        "Barangaroo",
        "City Circle",
        "Museum",
        "St James",
        "Martin Place",
        "North Sydney",
        "Chatswood",
        "Lindfield",
        "Gordon",
        "Hornsby via Gordon",
        "Hornsby via Lindfield",
        "Berowra via Gordon",
    ]

     /// The banner only shows city trains within this look-ahead window.
    static let lookAheadMinutes = 15

     /// Ashfield's TfNSW stop id, used as a startup fallback if the live `stop_finder`
     /// lookup fails (stable for the foreseeable future).
    static let ashfieldStopID = "213110"

    /// Wynyard Station's TfNSW stop id. TfNSW's journey endpoint accepts this station
    /// id and returns trains from Ashfield whose path includes Wynyard.
    static let wynyardStopID = "200080"

    static let `default` = NSWTrainConfig()

    init(apiKey: String = "",
         enabled: Bool = true,
         originStation: String = "Ashfield",
         stopID: String = "",
         destinationStation: String = "Wynyard",
         destinationStopID: String = NSWTrainConfig.wynyardStopID,
         destinationAllowlist: [String] = NSWTrainConfig.defaultDestinationAllowlist,
         pollIntervalSeconds: Double = 60,
         staleAfterSeconds: Double = 600) {
        self.apiKey = apiKey
        self.enabled = enabled
        self.originStation = originStation
        self.stopID = stopID
        self.destinationStation = destinationStation
        self.destinationStopID = destinationStopID
        self.destinationAllowlist = destinationAllowlist
        self.pollIntervalSeconds = pollIntervalSeconds
        self.staleAfterSeconds = staleAfterSeconds
     }

     /// The banner is only shown when explicitly enabled *and* a key is present.
    var isConfigured: Bool { self.enabled && !self.apiKey.isEmpty }
}

// MARK: - Pure helpers (the testable core)

enum NSWTrainSelection {
     /// `stop.class` for a train. The departure board also lists buses (e.g. 406/418),
     /// which are `product.class != 1`.
     static let trainProductClass = 1

     /// Fallback matching for the old `departure_mon` path. The preferred live path
     /// uses `trip` and does not depend on destination strings.
     static func matchesCity(destination: String, allowlist: [String]) -> Bool {
        let haystack = destination.lowercased()
        return allowlist.contains { !$0.isEmpty && haystack.contains($0.lowercased()) }
     }

     /// The up-to-`limit` soonest trains whose (best-known) departure is within
     /// `lookAheadMinutes` of `now`, sorted soonest-first. Used by the direct
     /// Ashfield → Wynyard journey path, where TfNSW has already done the route filter.
     static func nextDepartures(_ arrivals: [NSWTrainArrival],
                               now: Date,
                               lookAheadMinutes: Int = NSWTrainConfig.lookAheadMinutes,
                               limit: Int = 2) -> [NSWTrainArrival] {
        let horizon = now.addingTimeInterval(TimeInterval(lookAheadMinutes * 60))
        return arrivals
             .filter { $0.departure >= now && $0.departure <= horizon }
             .sorted { $0.departure < $1.departure }
             .prefix(limit)
             .map { $0 }
        }

     /// The up-to-`limit` soonest city-bound trains whose (best-known) departure is within
     /// `lookAheadMinutes` of `now`, sorted soonest-first.
     static func nextCitybound(_ arrivals: [NSWTrainArrival],
                              allowlist: [String],
                              now: Date,
                              lookAheadMinutes: Int = NSWTrainConfig.lookAheadMinutes,
                              limit: Int = 2) -> [NSWTrainArrival] {
        let horizon = now.addingTimeInterval(TimeInterval(lookAheadMinutes * 60))
        return arrivals
             .filter { $0.departure >= now && $0.departure <= horizon && self.matchesCity(destination: $0.destination, allowlist: allowlist) }
             .sorted { $0.departure < $1.departure }
             .prefix(limit)
             .map { $0 }
        }

     /// Whole minutes until `departure`, rounded *up*. A train 0–60s away reads as "now".
     static func minutesUntil(_ departure: Date, now: Date) -> Int {
        let seconds = departure.timeIntervalSince(now)
        if seconds <= 5 { return 0 }                 // within a minute → "now"
        return Int(ceil(seconds / 60.0))
        }

     /// "now" when the train is imminent, else "in N min".
     static func minutesText(until minutes: Int) -> String {
        minutes <= 0 ? "now" : "in \(minutes) min"
        }

     /// Two-digit 24-hour "HH:mm" in the supplied time zone (device local by default).
     static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
     }

     /// Build the banner rows from a set of arrivals: filter + rank + format, all at `now`.
     static func displayRows(from arrivals: [NSWTrainArrival],
                            now: Date,
                            timeZone: TimeZone = .current,
                            lookAheadMinutes: Int = NSWTrainConfig.lookAheadMinutes,
                            limit: Int = 2) -> [NSWTrainDisplayRow] {
        self.nextDepartures(arrivals, now: now,
                            lookAheadMinutes: lookAheadMinutes, limit: limit)
             .map { arrival in
                let minutes = self.minutesUntil(arrival.departure, now: now)
                return NSWTrainDisplayRow(
                    destination: arrival.destination,
                    clockText: self.clockText(arrival.departure, timeZone: timeZone),
                    minutesText: self.minutesText(until: minutes),
                    minutes: minutes)
         }
     }

     /// Fallback row builder for the old departure-board path.
     static func displayRows(from arrivals: [NSWTrainArrival],
                            allowlist: [String],
                            now: Date,
                            timeZone: TimeZone = .current,
                            lookAheadMinutes: Int = NSWTrainConfig.lookAheadMinutes,
                            limit: Int = 2) -> [NSWTrainDisplayRow] {
        self.nextCitybound(arrivals, allowlist: allowlist, now: now,
                            lookAheadMinutes: lookAheadMinutes, limit: limit)
             .map { arrival in
                let minutes = self.minutesUntil(arrival.departure, now: now)
                return NSWTrainDisplayRow(
                    destination: arrival.destination,
                    clockText: self.clockText(arrival.departure, timeZone: timeZone),
                    minutesText: self.minutesText(until: minutes),
                    minutes: minutes)
         }
     }

}
