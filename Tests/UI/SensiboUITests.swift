import XCTest

/// End-to-end test: launches the *real* app on the simulator in MOCK mode
/// (so it never touches your device) and drives the toggle through the UI.
///
/// This is the "prove it works" proof: a real UI, a real SwiftUI binding, a real
/// controller — only the network is substituted.
final class SensiboUITests: XCTestCase {

    var app: XCUIApplication!

     override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
        app = XCUIApplication()
              // Force the app to run without a network call to the real device.
        app.launchArguments = ["-SENSIBO_MOCK", "1"]
        app.launchEnvironment = ["SENSIBO_MOCK": "1"]
        app.launch()
          }

     override func tearDown() {
        self.app = nil
        super.tearDown()
        }

     func testAppLaunches() {
        let bar = self.app.navigationBars["Sensibo"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "app should show the Sensibo navigation bar")
          }

          /// Toggling a row in the UI flips its visual state end-to-end.
     func testToggleRowFlipsInUI() {
          // Wait for the first toggle to appear after load.
        let toggle = self.app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "a toggle should appear after load")

        let initial = (toggle.value as? String) == "1"
        toggle.tap()
        self.waitForToggleValue(toggle, on: !initial, timeout: 5)

        toggle.tap()
        self.waitForToggleValue(toggle, on: initial, timeout: 5)
          }

     func testAllFourSeededDevicesRender() {
          // Mock seeds 4 ACs; all should be visible.
        XCTAssertTrue(self.app.cells.firstMatch.waitForExistence(timeout: 10), "cells should render")
        XCTAssertGreaterThanOrEqual(self.app.switches.count, 4,
            "expected 4 toggles, got \(self.app.switches.count)")
          }

     private func waitForToggleValue(_ element: XCUIElement, on: Bool, timeout: TimeInterval) {
        let target = on ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == target { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
             }
        XCTAssertEqual(element.value as? String, target, "toggle did not reach \(on)")
           }
}
