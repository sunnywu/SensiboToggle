import XCTest

@MainActor
final class SensiboRealUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RUN_TAPO_LIVE_TOGGLE_TESTS"] == "1" else {
            throw XCTSkip("real UI toggle test is opt-in because it changes a real device")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.a.SensiboToggle")
        app.launchEnvironment = ["WALL_PANEL": "0"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testRealVerandahLightSwitchTogglesAndRestores() throws {
        try require(app.otherElements["device.dashboard"].waitForExistence(timeout: 15), "dashboard should appear")
        let toggle = try requireElement(waitForVerandahLightToggle(timeout: 15), "verandah light toggle should appear")
        try require(toggle.isHittable, "verandah light toggle should be tappable")
        try require(waitForNoTapoError(stableFor: 2, timeout: 8), "app should not show a Tapo error after launch")

        let original = isOn(toggle)
        let target = !original
        var changed = false
        defer {
            if changed, isOn(toggle) != original {
                toggle.tap()
                _ = waitForToggleValue(toggle, on: original, timeout: 8)
                _ = waitForToggleEnabled(toggle, timeout: 8)
            }
        }

        toggle.tap()
        try require(waitForToggleValue(toggle, on: target, timeout: 8), "verandah light switch should flip")
        try require(waitForToggleEnabled(toggle, timeout: 8), "verandah light switch should finish syncing")
        try require(waitForNoTapoError(stableFor: 2, timeout: 8), "tapping verandah light should not show a Tapo error")
        try require(isOn(toggle) == target, "verandah light switch should stay at the requested state")
        changed = true

        toggle.tap()
        try require(waitForToggleValue(toggle, on: original, timeout: 8), "verandah light switch should restore")
        try require(waitForToggleEnabled(toggle, timeout: 8), "verandah light switch should finish restoring")
        try require(waitForNoTapoError(stableFor: 2, timeout: 8), "restoring verandah light should not show a Tapo error")
        try require(isOn(toggle) == original, "verandah light switch should restore the original state")
        changed = false
    }

    private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? String) == "1"
    }

    private func waitForToggleValue(_ element: XCUIElement, on: Bool, timeout: TimeInterval) -> Bool {
        let target = on ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == target { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForToggleEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForVerandahLightToggle(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = [
                app.descendants(matching: .any)["light.toggle.verandah light"],
                app.buttons["verandah light"],
                app.descendants(matching: .any)["verandah light"],
            ]
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func hasTapoError() -> Bool {
        let errorText = app.staticTexts.matching(NSPredicate(format: [
            "label BEGINSWITH 'No Tapo'",
            "label BEGINSWITH 'No IP address configured for Tapo'",
            "label BEGINSWITH 'Tapo handshake failed'",
            "label BEGINSWITH 'Bad Tapo response'",
            "label BEGINSWITH 'Tapo session expired'",
            "label BEGINSWITH 'Tapo device error'",
            "label BEGINSWITH 'Network:'",
            "label == 'Could not reach Tapo.'",
        ].joined(separator: " OR ")))
        return errorText.firstMatch.exists
    }

    private func waitForNoTapoError(stableFor: TimeInterval, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var cleanSince: Date?
        while Date() < deadline {
            if hasTapoError() {
                cleanSince = nil
            } else {
                let now = Date()
                if cleanSince == nil { cleanSince = now }
                if now.timeIntervalSince(cleanSince!) >= stableFor { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if condition() { return }
        throw SensiboRealUITestError.failed(message)
    }

    private func requireElement(_ element: XCUIElement?, _ message: String) throws -> XCUIElement {
        guard let element else { throw SensiboRealUITestError.failed(message) }
        return element
    }
}

private enum SensiboRealUITestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}
