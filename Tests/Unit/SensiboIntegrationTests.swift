import XCTest
@testable import SensiboToggle

/// LIVE integration test. Runs against the *real* Sensibo API using the
/// (git-ignored) API key, for a single pod, and always restores it to its
/// original state so the user's device is never left changed.
///
/// The key is read from `config/local.config.json` (shipped into this test
/// bundle) with an environment override. If no key is available the test
/// skips cleanly. A 429 (API rate limit) is treated as a skip, not a failure.
final class SensiboIntegrationTests: XCTestCase {

    static let apiKey: String = {
        if let env = ProcessInfo.processInfo.environment["SENSIBO_LIVE_KEY"], !env.isEmpty {
            return env
            }
        guard let url = Bundle(for: SensiboIntegrationTests.self).url(forResource: "local", withExtension: "config.json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["apiKey"] as? String, !key.isEmpty else {
            return ""
            }
        return key
        }()

    static let baseURL: String = {
        ProcessInfo.processInfo.environment["SENSIBO_BASE_URL"]
            ?? "https://home.sensibo.com/api/v2"
        }()

    var client: SensiboClient?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["RUN_SENSIBO_LIVE_TESTS"] == "1" else {
            throw XCTSkip("live Sensibo tests are opt-in because they can change real devices")
        }
        guard !Self.apiKey.isEmpty else {
            throw XCTSkip("no API key available — skipping live test")
            }
        self.client = SensiboClient(baseURL: Self.baseURL, apiKey: Self.apiKey)
        }

        /// Convert a rate-limit into a clean skip; rethrow everything else with
        /// its error description so the failure is informative.
    private func skipOnRateLimit(_ error: Error) throws {
        if case let SensiboError.http(status, _) = error, status == 429 {
            throw XCTSkip("API rate limited (429) — skipping live test")
            }
        throw error
        }

          /// The real endpoint returns at least one device with a current state.
    func testLiveFetchPodsAndState() async throws {
        guard let client else { throw XCTSkip("no key") }
        do {
            let pods = try await client.pods()
            XCTAssertFalse(pods.isEmpty, "expected at least one pod from the live API")
            XCTAssertGreaterThanOrEqual(pods.count, 1)
              } catch is CancellationError {
             throw CancellationError()
            } catch let e as SensiboError {
                 try self.skipOnRateLimit(e)
               } catch {
             throw error
              }
          }

          /// Round-trip the real AC: read state, flip, verify, flip back, verify restored.
     func testLiveToggleRoundTrip() async throws {
        guard let client else { throw XCTSkip("no key") }
        let pods = try await self.fetchPodsOrSkip(client)
        guard let pod = pods.first else { throw XCTSkip("no pods returned") }

        let original = try await self.currentOnOrSkip(client, pod.id)
        let target = !original

        try await client.setCurrent(on: target, podId: pod.id)
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterSet = try await self.currentOnOrSkip(client, pod.id)
        XCTAssertEqual(afterSet, target, "state should match what we sent")

        try await client.setCurrent(on: original, podId: pod.id)
           /// give the device a moment, then verify restoration
        try await Task.sleep(nanoseconds: 500_000_000)
        let restored = try await self.currentOnOrSkip(client, pod.id)
        XCTAssertEqual(restored, original, "device should be restored to its original state")
      }

    private func fetchPodsOrSkip(_ client: SensiboClient) async throws -> [AirCon] {
        do { return try await client.pods() }
        catch let e as SensiboError {
            try self.skipOnRateLimit(e)
            throw e
        }
        catch is CancellationError { throw CancellationError() }
       }

    private func currentOnOrSkip(_ client: SensiboClient, _ podId: String) async throws -> Bool {
        do { return try await client.currentOn(podId: podId) }
        catch let e as SensiboError {
            try self.skipOnRateLimit(e)
            throw e
        }
        catch is CancellationError { throw CancellationError() }
        }
}
