import XCTest
@testable import SensiboToggle

final class ModelAndConfigTests: XCTestCase {

     func testDisplayNamePrefersRoom() {
        XCTAssertEqual(AirCon(id: "x", room: "Living Room").displayName, "Living Room")
        XCTAssertEqual(AirCon(id: "abcd1234", room: "").displayName, "AC 1234")
        XCTAssertEqual(AirCon(id: "zz", name: "Floor", room: nil).displayName, "Floor")
         }

     func testSymbolReflectsOn() {
        XCTAssertTrue(AirCon(id: "x", room: "r", on: true).symbol.contains("flame"))
        XCTAssertTrue(AirCon(id: "x", room: "r", on: false).symbol.contains("snowflake"))
        }

     func testErrorDescriptions() {
        XCTAssertEqual(SensiboError.noApikey.localizedDescription, "No API key configured.")
        XCTAssertTrue(SensiboError.http(status: 429, body: "").localizedDescription.contains("429"))
        XCTAssertTrue(SensiboError.transport("nope").localizedDescription.contains("Network"))
        XCTAssertTrue(SensiboError.decoding("bad").localizedDescription.contains("Bad"))
       }

        /// Hermetic: force mock mode via environment without a bundle key.
     func testMockModeFromEnvironment() {
        setenv("SENSIBO_MOCK", "1", 1)
        defer { unsetenv("SENSIBO_MOCK") }
        XCTAssertTrue(Config.load().mockMode)
          }

     func testLiveModeWhenKeyPresent() {
        setenv("SENSIBO_API_KEY", "unit-test-key", 1)
        setenv("SENSIBO_MOCK", "0", 1)
        defer {
            unsetenv("SENSIBO_API_KEY")
            unsetenv("SENSIBO_MOCK")
             }
        let config = Config.load()
        XCTAssertEqual(config.apiKey, "unit-test-key")
        XCTAssertFalse(config.mockMode)
          }

     func testTapoConfigParsesNestedCredentialsAndDevices() {
        let config = Config.appConfig(from: [
            "apiKey": "unit-test-key",
            "baseURL": "https://example.test",
            "mockMode": false,
            "tapo": [
                "email": "user@example.test",
                "password": "password",
                "devices": [
                    ["name": "Verandah", "ip": "192.0.2.10", "type": "P110"],
                ],
            ],
        ], environment: [:])

        XCTAssertEqual(config.tapoEmail, "user@example.test")
        XCTAssertEqual(config.tapoPassword, "password")
        XCTAssertEqual(config.tapoDevices, [
            TapoDeviceConfig(name: "Verandah", ip: "192.0.2.10", type: "P110"),
        ])
     }

     func testTapoDeviceIPCanComeFromEnvironment() {
        let config = Config.appConfig(from: [
            "apiKey": "unit-test-key",
            "tapo": [
                "email": "user@example.test",
                "password": "password",
            ],
        ], environment: [
            "TAPO_DEVICE_NAME": "Desk",
            "TAPO_DEVICE_IP": "192.0.2.22",
            "TAPO_DEVICE_TYPE": "L530",
        ])

        XCTAssertEqual(config.tapoDevices, [
            TapoDeviceConfig(name: "Desk", ip: "192.0.2.22", type: "L530"),
        ])
     }

     func testAirConTemperatureDisplay() {
        let ac1 = AirCon(id: "test", room: "Living Room", on: true, temperature: 22.5, mode: "cool")
        XCTAssertEqual(ac1.temperatureDisplay, "22°")

        let ac2 = AirCon(id: "test2", room: "Bedroom", on: false, temperature: nil, mode: nil)
        XCTAssertEqual(ac2.temperatureDisplay, "-")
      }
    // MARK: - Wall-panel / kiosk configuration

    /// Defaults: kiosk is OFF and the idle delay is 15s (the requested default),
    /// so a normal install is completely unaffected.
    func testWallPanelDefaultsOffAndFifteenSeconds() {
        let config = Config.appConfig(from: [:], environment: [:])
        XCTAssertFalse(config.wallPanelEnabled)
        XCTAssertEqual(config.wallPanelIdleSeconds, 15.0)
    }

    /// Nested `wallPanel.enabled` / `wallPanel.idleSeconds` enable and configure
    /// kiosk mode straight from `local.config.json`.
    func testWallPanelFromNestedJson() {
        let config = Config.appConfig(from: [
            "wallPanel": [
                "enabled": true,
                "idleSeconds": 5,
            ],
        ], environment: [:])
        XCTAssertTrue(config.wallPanelEnabled)
        XCTAssertEqual(config.wallPanelIdleSeconds, 5.0)
    }

    /// Flat `wallPanelEnabled` / `wallPanelIdleSeconds` keys are also accepted and
    /// a string idle value parses to a `Double`.
    func testWallPanelFromFlatJson() {
        let config = Config.appConfig(from: [
            "wallPanelEnabled": true,
            "wallPanelIdleSeconds": "8",
        ], environment: [:])
        XCTAssertTrue(config.wallPanelEnabled)
        XCTAssertEqual(config.wallPanelIdleSeconds, 8.0)
    }

    /// An environment flag overrides the JSON (same precedence as `tapo`).
    func testWallPanelEnvOverridesJson() {
        let config = Config.appConfig(from: [
            "wallPanel": ["enabled": true, "idleSeconds": 7],
        ], environment: ["WALL_PANEL": "0", "WALL_PANEL_IDLE_SECONDS": "3"])
        XCTAssertFalse(config.wallPanelEnabled, "WALL_PANEL=0 must win over json true")
        XCTAssertEqual(config.wallPanelIdleSeconds, 3.0)
    }

    /// Mock mode (forced by env, no explicit kiosk flag) keeps kiosk OFF so the
    /// blank overlay can never cover the UI while XCUITest is driving it.
    func testMockModeKeepsKioskOffUnlessExplicitlyRequested() {
        setenv("SENSIBO_MOCK", "1", 1)
        defer { unsetenv("SENSIBO_MOCK") }

        let off = Config.load()
        XCTAssertFalse(off.wallPanelEnabled, "mock is kiosk-off by default")

        setenv("WALL_PANEL", "1", 1)
        setenv("WALL_PANEL_IDLE_SECONDS", "1", 1)
        defer {
            unsetenv("WALL_PANEL")
            unsetenv("WALL_PANEL_IDLE_SECONDS")
        }
        let on = Config.load()
        XCTAssertTrue(on.wallPanelEnabled, "WALL_PANEL=1 in mock enables a preview")
        XCTAssertEqual(on.wallPanelIdleSeconds, 1.0)
    }

    /// The flag / number parsers accept common spellings and reject typos.
    func testWallPanelBoolParsing() {
        XCTAssertEqual(Config.parseBool("1"), true)
        XCTAssertEqual(Config.parseBool("true"), true)
        XCTAssertEqual(Config.parseBool("ON"), true)
        XCTAssertEqual(Config.parseBool("0"), false)
        XCTAssertEqual(Config.parseBool("no"), false)
        XCTAssertNil(Config.parseBool("garbage"))
        XCTAssertEqual(Config.parseDouble("12.5"), 12.5)
        XCTAssertEqual(Config.parseDouble(12), 12.0)
        XCTAssertNil(Config.parseDouble("not-a-number"))
    }


    // MARK: - Polling configuration

    /// The polling interval defaults to 30s (the requested default) so a plain
    /// install polls without any config.
    func testPollIntervalDefaultsToThirty() {
        let config = Config.appConfig(from: [:], environment: [:])
        XCTAssertEqual(config.pollIntervalSeconds, 30.0)
        }

    /// A nested `polling.intervalSeconds` (or the shorter `polling.interval`) configures it.
    func testPollFromNestedJson() {
        let five = Config.appConfig(from: ["polling": ["intervalSeconds": 5.0]], environment: [:])
        XCTAssertEqual(five.pollIntervalSeconds, 5.0)

        let seven = Config.appConfig(from: ["polling": ["interval": 7]], environment: [:])
        XCTAssertEqual(seven.pollIntervalSeconds, 7.0, "the shorter `interval` key is honoured too")
        }

    /// A flat `pollIntervalSeconds` key is accepted, and a string value parses to a Double.
    func testPollFromFlatJson() {
        let config = Config.appConfig(from: ["pollIntervalSeconds": "8"], environment: [:])
        XCTAssertEqual(config.pollIntervalSeconds, 8.0)
        }

    /// An environment override wins over nested/flat JSON, matching tapo/wallPanel precedence.
    func testPollEnvOverridesJson() {
        let config = Config.appConfig(from: ["polling": ["intervalSeconds": 7.0]],
                                      environment: ["SENSIBO_POLL_INTERVAL": "3"])
        XCTAssertEqual(config.pollIntervalSeconds, 3.0, "SENSIBO_POLL_INTERVAL must win over JSON")
        }

    /// A nested interval of 0 disables polling at the config layer.
    func testPollZeroIntervalDisables() {
        let config = Config.appConfig(from: ["polling": ["intervalSeconds": 0]], environment: [:])
        XCTAssertEqual(config.pollIntervalSeconds, 0.0)
        }

    /// Mock mode forces polling OFF by default so XCUITest is hermetic; only
    /// SENSIBO_POLL_INTERVAL re-enables it (for an in-simulator preview).
    func testMockModeKeepsPollingOffUnlessRequested() {
        setenv("SENSIBO_MOCK", "1", 1)
        defer { unsetenv("SENSIBO_MOCK") }
        var off = Config.load()
        XCTAssertEqual(off.pollIntervalSeconds, 0.0, "mock is poll-off by default")

        setenv("SENSIBO_POLL_INTERVAL", "5", 1)
        defer { unsetenv("SENSIBO_POLL_INTERVAL") }
        off = Config.load()
        XCTAssertEqual(off.pollIntervalSeconds, 5.0, "SENSIBO_POLL_INTERVAL=5 re-enables in mock")
        }

}
