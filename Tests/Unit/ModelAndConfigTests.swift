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

     func testAirConTemperatureDisplay() {
        let ac1 = AirCon(id: "test", room: "Living Room", on: true, temperature: 22.5, mode: "cool")
        XCTAssertEqual(ac1.temperatureDisplay, "22°")

        let ac2 = AirCon(id: "test2", room: "Bedroom", on: false, temperature: nil, mode: nil)
        XCTAssertEqual(ac2.temperatureDisplay, "-")
      }
}
