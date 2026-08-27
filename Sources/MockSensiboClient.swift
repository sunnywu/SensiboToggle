import Foundation

/// An in-memory Sensibo double. Used by XCUITest and by app launch in "mock" mode
/// so the entire UI can be exercised and proven with zero network latency.
///
/// `@MainActor` keeps it single-threaded and trivially `Sendable` (all stored
/// state is main-actor-owned, matching how the controller reaches it).
@MainActor
final class MockSensiboClient: SensiboClientProtocol {
    private var store: [String: AirCon]

    init(seed: [AirCon]) {
        self.store = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
      }

    func pods() async throws -> [AirCon] {
        Array(self.store.values).sorted { $0.displayName < $1.displayName }
      }

    func setCurrent(on: Bool, podId: String) async throws {
        if var existing = self.store[podId] {
            existing.on = on
            self.store[podId] = existing
         } else {
            self.store[podId] = AirCon(id: podId, name: "", room: nil, on: on, temperature: nil, mode: nil)
            }
        }

    func setTemperature(_ temperature: Double?, for podId: String) async throws {
        if var existing = self.store[podId] {
            existing.temperature = temperature
            self.store[podId] = existing
         } else {
            self.store[podId] = AirCon(id: podId, name: "", room: nil, on: true, temperature: temperature, mode: nil)
            }
        }

    func current(on podId: String) -> Bool {
        self.store[podId]?.on ?? false
       }
}
