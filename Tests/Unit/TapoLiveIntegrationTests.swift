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

    private static func liveConfigOrSkip() throws -> LiveConfig {
        let config = Config.load()
        guard !config.tapoEmail.isEmpty, !config.tapoPassword.isEmpty else {
            throw XCTSkip("no Tapo credentials configured")
        }
        guard let device = config.tapoDevices.first, !device.ip.isEmpty else {
            throw XCTSkip("no Tapo device IP configured")
        }
        return LiveConfig(email: config.tapoEmail, password: config.tapoPassword, device: device)
    }
}
