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
}
