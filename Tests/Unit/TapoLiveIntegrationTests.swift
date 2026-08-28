import XCTest
@testable import SensiboToggle

/// Live Tapo integration tests backed by git-ignored `config/local.config.json`.
///
/// The default live test is read-only: it performs the KLAP handshake and reads
/// `device_on`, which proves credentials/IP/protocol wiring without changing the
/// real device. The round-trip toggle is a separate, stronger opt-in test.
final class TapoLiveIntegrationTests: XCTestCase {
    private struct LiveConfig {
        let email: String
        let password: String
        let device: TapoDeviceConfig
    }

    func testLiveStatusReadsConfiguredDevice() async throws {
        guard ProcessInfo.processInfo.environment["RUN_TAPO_LIVE_TESTS"] == "1" else {
            throw XCTSkip("live Tapo tests are opt-in because they reach a real local device")
        }

        let live = try Self.liveConfigOrSkip()
        let client = KLAPTapoClient(email: live.email, password: live.password, devices: [live.device])

        _ = try await client.status(device: live.device.name)
    }

    func testLiveTurnsOnVerandahLight() async throws {
        guard ProcessInfo.processInfo.environment["RUN_TAPO_LIVE_TURN_ON_TEST"] == "1" else {
            throw XCTSkip("live Tapo turn-on test is opt-in because it changes a real device")
        }

        let live = try Self.liveConfigOrSkip(deviceName: "verandah light")
        let client = KLAPTapoClient(email: live.email, password: live.password, devices: [live.device])

        try await client.set(on: true, device: live.device.name)
        try await Task.sleep(nanoseconds: 350_000_000)

        let afterSet = try await client.status(device: live.device.name)
        XCTAssertTrue(afterSet, "verandah light should be on after sending the Tapo on command")
    }

    func testLiveTurnsOnConfiguredVerandahLight() async throws {
        guard ProcessInfo.processInfo.environment["RUN_TAPO_LIVE_TARGET_TEST"] == "1" else {
            throw XCTSkip("live Tapo target test is opt-in because it changes a real device")
        }

        let live = try Self.liveConfigOrSkip(deviceName: "verandah light")
        let client = KLAPTapoClient(email: live.email, password: live.password, devices: [live.device])

        try await client.set(on: true, device: live.device.name)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let info = try await client.deviceInfo(device: live.device.name)
        let afterSet = try await client.status(device: live.device.name)
        let summary = Self.safeSummary(info: info)

        XCTAssertTrue(afterSet, "verandah light should be on after sending the Tapo on command. \(summary)")
    }

    func testLiveToggleRoundTripRestoresState() async throws {
        guard ProcessInfo.processInfo.environment["RUN_TAPO_LIVE_TOGGLE_TESTS"] == "1" else {
            throw XCTSkip("live Tapo toggle test is opt-in because it changes a real device")
        }

        let live = try Self.liveConfigOrSkip()
        let client = KLAPTapoClient(email: live.email, password: live.password, devices: [live.device])
        let original = try await client.status(device: live.device.name)
        let target = !original

        do {
            try await client.set(on: target, device: live.device.name)
            try await Task.sleep(nanoseconds: 350_000_000)
            let afterSet = try await client.status(device: live.device.name)
            XCTAssertEqual(afterSet, target)

            try await client.set(on: original, device: live.device.name)
            try await Task.sleep(nanoseconds: 350_000_000)
            let restored = try await client.status(device: live.device.name)
            XCTAssertEqual(restored, original)
        } catch {
            _ = try? await client.set(on: original, device: live.device.name)
            throw error
        }
    }

    private static func liveConfigOrSkip(deviceName: String? = nil) throws -> LiveConfig {
        let config = Config.load()
        guard !config.tapoEmail.isEmpty, !config.tapoPassword.isEmpty else {
            throw XCTSkip("no Tapo credentials configured")
        }
        let device = deviceName.flatMap { wanted in
            config.tapoDevices.first { $0.name == wanted }
        } ?? config.tapoDevices.first
        guard let device, !device.ip.isEmpty else {
            throw XCTSkip("no Tapo device IP configured")
        }
        return LiveConfig(email: config.tapoEmail, password: config.tapoPassword, device: device)
    }

    private static func safeSummary(info: [String: Any]) -> String {
        let nickname = info["nickname"] as? String ?? "unknown"
        let model = info["model"] as? String ?? info["type"] as? String ?? "unknown"
        let deviceOn = info["device_on"] as? Bool
        return "nickname=\(nickname), model=\(model), device_on=\(String(describing: deviceOn))"
    }
}
