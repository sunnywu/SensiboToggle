import XCTest
import Foundation
@testable import SensiboToggle

// Hermetic tests for the next-train banner: arrival parsing, city matching,
// next-two selection, minute math, config parsing, and the controller's
// load / keep-last-good / stale state machine. No wall clock (injected `now`),
// no network (`MockNSWTrainClient`). `poll()` is driven directly and `setNow`
// pins the clock, so these never touch a real device.
//
// Note: controller-path `text` uses the *device-local* time zone, which isn't
// fixed in a unit test, so those tests assert the time-zone-independent fields
// (`destination` / `minutesText`); the deterministic `clockText` format is
// covered separately with an explicit time zone.

private func utc(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

private func decode(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any])
}

// MARK: - selection, matching, math

final class NSWTrainSelectionTests: XCTestCase {

    func testCityMatchIsSubstringCaseInsensitive() {
        XCTAssertTrue(NSWTrainSelection.matchesCity(destination: "Wynyard via St Leonards", allowlist: ["Wynyard"]))
        XCTAssertTrue(NSWTrainSelection.matchesCity(destination: "Circular Quay", allowlist: ["circular quay"]))
        XCTAssertFalse(NSWTrainSelection.matchesCity(destination: "Glebe via Ashfield", allowlist: ["Wynyard", "Central", "Town Hall"]))
        XCTAssertFalse(NSWTrainSelection.matchesCity(destination: "", allowlist: ["Wynyard"]))
        XCTAssertFalse(NSWTrainSelection.matchesCity(destination: "Wynyard", allowlist: []))     // empty allowlist matches nothing
      }

    func testAshfieldCityboundDestinationsFromLiveFeedShape() {
        let allowlist = NSWTrainConfig.default.destinationAllowlist
        XCTAssertTrue(NSWTrainSelection.matchesCity(destination: "Gordon via Lindfield", allowlist: allowlist))
        XCTAssertTrue(NSWTrainSelection.matchesCity(destination: "Hornsby via Gordon", allowlist: allowlist))
        XCTAssertFalse(NSWTrainSelection.matchesCity(destination: "Hornsby via Strathfield", allowlist: allowlist))
        XCTAssertFalse(NSWTrainSelection.matchesCity(destination: "Penrith via Parramatta", allowlist: allowlist))
    }

    func testMinutesCeilAndNowWithinAMinute() {
        let now = utc("2026-08-30T06:30:00Z")
          // 0–5s away reads as "now".
        XCTAssertEqual(NSWTrainSelection.minutesUntil(now.addingTimeInterval(5), now: now), 0)
        XCTAssertEqual(NSWTrainSelection.minutesText(until: 0), "now")
          // 7m40s away ceils to 8.
        XCTAssertEqual(NSWTrainSelection.minutesUntil(now.addingTimeInterval(7 * 60 + 40), now: now), 8)
        XCTAssertEqual(NSWTrainSelection.minutesText(until: 8), "in 8 min")
          // A past train is still "now".
        XCTAssertEqual(NSWTrainSelection.minutesText(until: -3), "now")
      }

    func testClockIsTwoDigitLocalTime() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(NSWTrainSelection.clockText(utc("2026-08-30T06:05:00Z"), timeZone: tz), "06:05")
      }

    func testNextTwoSortedCityOnlyAndWithinWindow() {
        let now = utc("2026-08-30T06:30:00Z")
        let arrivals = [
               // excluded: outbound destination
             NSWTrainArrival(destination: "Glebe via Ashfield", departure: now.addingTimeInterval(3 * 60)),
               // excluded: in the past
             NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(-60)),
               // excluded: beyond the 15-min look-ahead window
             NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(20 * 60)),
               // the three valid city trains
             NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(7 * 60)),
             NSWTrainArrival(destination: "Town Hall", departure: now.addingTimeInterval(14 * 60)),
             NSWTrainArrival(destination: "Central via Wynyard", departure: now.addingTimeInterval(12 * 60)),
         ]
        let pick = NSWTrainSelection.nextCitybound(
             arrivals, allowlist: ["Wynyard", "Central", "Town Hall"],
             now: now, lookAheadMinutes: 15, limit: 2)
        XCTAssertEqual(pick.count, 2)
          // soonest two: the 7-min and 12-min trains.
        XCTAssertEqual(pick[0].departure, now.addingTimeInterval(7 * 60))
        XCTAssertEqual(pick[1].departure, now.addingTimeInterval(12 * 60))
      }

    func testNextTwoHandlesAshfieldLiveFeedDestinations() {
        let now = utc("2026-08-30T10:27:00Z")
        let arrivals = [
            NSWTrainArrival(destination: "Penrith via Parramatta", departure: now.addingTimeInterval(2 * 60)),
            NSWTrainArrival(destination: "Gordon via Lindfield", departure: now.addingTimeInterval(9 * 60)),
            NSWTrainArrival(destination: "Hornsby via Gordon", departure: now.addingTimeInterval(13 * 60)),
            NSWTrainArrival(destination: "Hornsby via Strathfield", departure: now.addingTimeInterval(12 * 60)),
        ]
        let pick = NSWTrainSelection.nextCitybound(
            arrivals,
            allowlist: NSWTrainConfig.default.destinationAllowlist,
            now: now,
            lookAheadMinutes: 15,
            limit: 2)
        XCTAssertEqual(pick.map(\.destination), ["Gordon via Lindfield", "Hornsby via Gordon"])
    }

    func testDirectJourneyDeparturesDoNotNeedDestinationAllowlist() {
        let now = utc("2026-08-30T10:45:00Z")
        let arrivals = [
            NSWTrainArrival(destination: "Lindfield", departure: now.addingTimeInterval(6 * 60)),
            NSWTrainArrival(destination: "Hornsby via Gordon", departure: now.addingTimeInterval(9 * 60)),
            NSWTrainArrival(destination: "Chatswood", departure: now.addingTimeInterval(20 * 60)),
        ]
        let pick = NSWTrainSelection.nextDepartures(
            arrivals,
            now: now,
            lookAheadMinutes: 15,
            limit: 2)
        XCTAssertEqual(pick.map(\.destination), ["Lindfield", "Hornsby via Gordon"])
    }

    func testEmptyWhenNoCityTrainInWindow() {
        let now = utc("2026-08-30T06:30:00Z")
          // City-bound, but 60 min out — beyond the 15-min window.
        let arrivals = [NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(3600))]
        XCTAssertTrue(NSWTrainSelection.nextCitybound(arrivals, allowlist: ["Wynyard"], now: now, lookAheadMinutes: 15, limit: 2).isEmpty)
      }

    func testDisplayRowsFormat() {
        let now = utc("2026-08-30T06:30:00Z")
        let rows = NSWTrainSelection.displayRows(
             from: [
                   NSWTrainArrival(destination: "Wynyard via St Leonards", departure: now.addingTimeInterval(7 * 60)),
                   NSWTrainArrival(destination: "Town Hall", departure: now.addingTimeInterval(14 * 60)),
               ],
             allowlist: ["Wynyard", "Town Hall"],
             now: now,
             timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "7 min 🚃 Wynyard via St Leonards 06:37")
        XCTAssertEqual(rows[1].text, "14 min 🚃 Town Hall 06:44")
      }
}

// MARK: - rapidJSON parsing

final class NSWTrainParsingTests: XCTestCase {

    func testJourneyParserUsesFirstTrainLegFromAshfieldToWynyard() throws {
        let json = """
          {"journeys":[
            {"legs":[
              {"origin":{"name":"Ashfield Station, Ashfield"},
               "destination":{"name":"Ashfield Station, Platform 3, Ashfield"},
               "transportation":{"product":{"class":99}}},
              {"origin":{"name":"Ashfield Station, Platform 3, Ashfield",
                         "departureTimeEstimated":"2026-08-30T10:51:00Z",
                         "departureTimePlanned":"2026-08-30T10:49:00Z"},
               "destination":{"name":"Wynyard Station, Platform 4, Sydney"},
               "transportation":{"product":{"class":1},
                                 "destination":{"name":"Lindfield"}},
               "stopSequence":[
                 {"name":"Ashfield Station, Platform 3, Ashfield"},
                 {"name":"Redfern Station, Platform 5, Eveleigh"},
                 {"name":"Wynyard Station, Platform 4, Sydney"}
               ]}]},
            {"legs":[
              {"origin":{"name":"Ashfield Station, Platform 3, Ashfield",
                         "departureTimePlanned":"2026-08-30T10:54:00Z"},
               "destination":{"name":"Wynyard Station, Platform 4, Sydney"},
               "transportation":{"product":{"class":1},
                                 "destination":{"name":"Hornsby via Gordon"}}}]},
            {"legs":[
              {"origin":{"name":"Ashfield Station, Stand A, Ashfield",
                         "departureTimePlanned":"2026-08-30T10:55:00Z"},
               "destination":{"name":"Wynyard Station, Sydney"},
               "transportation":{"product":{"class":5},
                                 "destination":{"name":"Wynyard"}}}]}
          ]}
          """
        let arrivals = NSWTrainClient.parseJourneyDepartures(try decode(json))
        XCTAssertEqual(arrivals.count, 2)
        XCTAssertEqual(arrivals[0], NSWTrainArrival(destination: "Lindfield", departure: utc("2026-08-30T10:51:00Z")))
        XCTAssertEqual(arrivals[1], NSWTrainArrival(destination: "Hornsby via Gordon", departure: utc("2026-08-30T10:54:00Z")))
    }

    func testTrainsOnlyAndPrefersEstimatedTime() throws {
        let json = """
          {"stopEvents":[
            {"departureTimeEstimated":"2026-08-30T06:32:00Z",
             "departureTimePlanned":"2026-08-30T06:31:00Z",
             "transportation":{"number":"42","productName":"Train","product":{"class":1},
                "destination":{"name":"Wynyard via St Leonards"}}},
            {"departureTimePlanned":"2026-08-30T06:35:00Z",
             "transportation":{"number":"X18","productName":"Bus","product":{"class":5},
                "destination":{"name":"Wynyard"}}},
            {"departureTimePlanned":"2026-08-30T06:36:00Z",
             "transportation":{"number":"N5","product":{"class":1},
                "destination":{"name":""}}}
          ]}
          """
        let arrivals = NSWTrainClient.parseDepartures(try decode(json))
          // The bus (class 5) and the empty-destination train are both dropped.
        XCTAssertEqual(arrivals.count, 1)
        XCTAssertEqual(arrivals[0].destination, "Wynyard via St Leonards")
          // The estimated time (06:32) wins over the planned time (06:31).
        XCTAssertEqual(arrivals[0].departure, utc("2026-08-30T06:32:00Z"))
      }

    func testNoEventsKeyIsEmptyNotError() {
        XCTAssertTrue(NSWTrainClient.parseDepartures(["stopEvents": [Any]()]).isEmpty)
        XCTAssertTrue(NSWTrainClient.parseDepartures([:]).isEmpty)    // absent key isn't an error
      }
}

// MARK: - config

final class NSWTrainConfigTests: XCTestCase {

    func testDefaultsAreSafe() {
        let d = NSWTrainConfig.default
        XCTAssertFalse(d.isConfigured)                   // no key → hidden even when enabled
        XCTAssertEqual(d.pollIntervalSeconds, 60)
        XCTAssertEqual(d.staleAfterSeconds, 600)
        XCTAssertEqual(d.stopID, "")
        XCTAssertEqual(d.destinationStation, "Wynyard")
        XCTAssertEqual(d.destinationStopID, NSWTrainConfig.wynyardStopID)
        XCTAssertEqual(NSWTrainConfig.ashfieldStopID, "213110")
        XCTAssertEqual(NSWTrainConfig.wynyardStopID, "200080")
        XCTAssertEqual(d.destinationAllowlist, [
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
        ])
      }

    func testEnvOverridesJSONOverridesDefault() throws {
        let json = """
          {"nswTrain":{"enabled":true,"apiKey":"from-json","stopID":"999",
            "destinationStation":"Town Hall","destinationStopID":"200060",
            "destinationAllowlist":["Wynyard","Glebe"],"pollIntervalSeconds":90,"staleAfterSeconds":120}}
          """
        let obj = try decode(json)
        var env = ["NSW_TRAIN_API_KEY": "from-env",
                   "NSW_TRAIN_POLL_INTERVAL": "30",
                   "NSW_TRAIN_DESTINATION_STOP_ID": NSWTrainConfig.wynyardStopID]

         // Env wins over the JSON block.
        var cfg = Config.parseNSWTrain(obj, environment: env, mockMode: false)
        XCTAssertEqual(cfg.apiKey, "from-env")
        XCTAssertEqual(cfg.pollIntervalSeconds, 30)
        XCTAssertEqual(cfg.stopID, "999")
        XCTAssertEqual(cfg.destinationStation, "Town Hall")
        XCTAssertEqual(cfg.destinationStopID, NSWTrainConfig.wynyardStopID)
        XCTAssertEqual(cfg.destinationAllowlist, ["Wynyard", "Glebe"])
        XCTAssertEqual(cfg.staleAfterSeconds, 120)

         // With env cleared, the JSON block applies.
        env = [:]
        cfg = Config.parseNSWTrain(obj, environment: env, mockMode: false)
        XCTAssertEqual(cfg.apiKey, "from-json")
        XCTAssertEqual(cfg.pollIntervalSeconds, 90)
        XCTAssertEqual(cfg.destinationStation, "Town Hall")
        XCTAssertEqual(cfg.destinationStopID, "200060")
      }

    func testMockModeForcesPollIntervalToZeroUnlessEnv() throws {
        let json = """
          {"nswTrain":{"enabled":true,"apiKey":""}}
          """
        let obj = try decode(json)
         // Mock mode: with no interval → forced to 0, so polling stays off → hermetic UI tests.
        var cfg = Config.parseNSWTrain(obj, environment: [:], mockMode: true)
        XCTAssertEqual(cfg.pollIntervalSeconds, 0)
          // But an explicit env override still wins, letting a UI test force a refresh.
        cfg = Config.parseNSWTrain(obj, environment: ["NSW_TRAIN_POLL_INTERVAL": "10"], mockMode: true)
        XCTAssertEqual(cfg.pollIntervalSeconds, 10)
      }

    func testMalformedBlockFallsBackToDefaults() throws {
        let broken = """
          {"nswTrain":{"pollIntervalSeconds":"nope","staleAfterSeconds":""}}
          """
        let cfg = Config.parseNSWTrain(try decode(broken), environment: [:], mockMode: false)
        XCTAssertEqual(cfg.pollIntervalSeconds, 60)
        XCTAssertEqual(cfg.staleAfterSeconds, 600)
        XCTAssertEqual(cfg.destinationStation, "Wynyard")
        XCTAssertEqual(cfg.destinationStopID, NSWTrainConfig.wynyardStopID)
        XCTAssertEqual(cfg.destinationAllowlist, NSWTrainConfig.default.destinationAllowlist)
      }
}

// MARK: - controller state machine (injected clock, fake client, direct `poll()`)

@MainActor
final class NSWTrainControllerTests: XCTestCase {

    private func makeController(seed: [NSWTrainArrival],
                                stale: TimeInterval = 1000) -> (NSWTrainController, MockNSWTrainClient) {
         // Poll interval 0 keeps the scheduler inert; we drive `poll()` by hand.
        let cfg = NSWTrainConfig(apiKey: "k", enabled: true, stopID: "213110",
                                 destinationStopID: NSWTrainConfig.wynyardStopID,
                                 destinationAllowlist: [],
                                 pollIntervalSeconds: 0, staleAfterSeconds: stale)
        let mock = MockNSWTrainClient(resolvedStopID: "213110", seed: seed)
        let c = NSWTrainController(config: cfg, client: mock, scheduler: ManualIdleScheduler())
        return (c, mock)
      }

    func testHiddenWhenNotConfigured() async {
        let c = NSWTrainController(config: .default, client: MockNSWTrainClient(seed: []), scheduler: ManualIdleScheduler())
        c.warmup()
        XCTAssertEqual(c.state, .hidden)
      }

    func testPollLoadsNextTwo() async {
        let now = utc("2026-08-30T06:30:00Z")
        let seed = [
             NSWTrainArrival(destination: "Lindfield", departure: now.addingTimeInterval(7 * 60)),
             NSWTrainArrival(destination: "Hornsby via Gordon", departure: now.addingTimeInterval(14 * 60)),
             NSWTrainArrival(destination: "Chatswood", departure: now.addingTimeInterval(20 * 60)),     // excluded: outside window
         ]
        let (c, _) = makeController(seed: seed)
        c.setNow { now }
        await c.poll()
        guard case .next(let rows) = c.state else { return XCTFail("expected .next, got \(c.state)") }
        XCTAssertEqual(rows.count, 2)
          // time-zone-independent fields (clockText uses the device locale in the controller).
        XCTAssertEqual(rows[0].destination, "Lindfield")
        XCTAssertEqual(rows[0].minutesText, "in 7 min")
        XCTAssertEqual(rows[1].destination, "Hornsby via Gordon")
        XCTAssertEqual(rows[1].minutesText, "in 14 min")
      }

    func testEmptyWhenNoCityTrainInWindow() async {
        let now = utc("2026-08-30T06:30:00Z")
        let (c, _) = makeController(seed: [NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(3600))])
        c.setNow { now }
        await c.poll()
        XCTAssertEqual(c.state, .empty)
      }

    func testKeepsLastGoodOnTransientFailure() async {
        let now = utc("2026-08-30T06:30:00Z")
        let (c, mock) = makeController(seed: [NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(7 * 60))], stale: 1000)
        c.setNow { now }
        await c.poll()                                     // good → .next (rows frozen at this `now`)
        guard case .next(let firstRows) = c.state else { return XCTFail("expected .next after first poll") }
        mock.failNextCount(5)                               // every subsequent poll throws
        let later = now.addingTimeInterval(120)           // 120s < 1000s stale threshold
        c.setNow { later }
        await c.poll()
          // The last good value is held in place, unfrozen by the new `now`.
        guard case .next(let held) = c.state else { return XCTFail("expected held .next, got \(c.state)") }
        XCTAssertEqual(held, firstRows)
      }

    func testStaleAfterThreshold() async {
        let now = utc("2026-08-30T06:30:00Z")
        let (c, mock) = makeController(seed: [NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(7 * 60))], stale: 10)
        c.setNow { now }
        await c.poll()                                      // good
        mock.failNextCount(5)
        let later = now.addingTimeInterval(11)           // 11s > 10s → past threshold
        c.setNow { later }
        await c.poll()
        XCTAssertEqual(c.state, .stale)
      }

    func testStalePersistsWhileFetchesKeepFailing() async {
        let now = utc("2026-08-30T06:30:00Z")
        let (c, mock) = makeController(seed: [NSWTrainArrival(destination: "Wynyard", departure: now.addingTimeInterval(7 * 60))], stale: 10)
        c.setNow { now }
        await c.poll()
        mock.failNextCount(5)
        c.setNow { now.addingTimeInterval(11) }
        await c.poll()
        XCTAssertEqual(c.state, .stale)
        c.setNow { now.addingTimeInterval(60) }         // still failing, still stale
        await c.poll()
        XCTAssertEqual(c.state, .stale)
      }
}
