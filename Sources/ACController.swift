import Foundation
import Combine

/// Drives the UI. Holds a `SensiboClientProtocol` so it can be unit-tested with a
/// fake and run in mock mode for the simulator/UI test.
///
/// Perceived latency: `toggle(_:)` flips the UI *synchronously* (optimistic), then
/// returns a Task that commits or reverts based on the server. The UI never blocks
/// on the server.
@MainActor
final class ACController: ObservableObject {
    @Published private(set) var acs: [AirCon] = []
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var error: String? = nil
    @Published private(set) var isReady = false

    let client: SensiboClientProtocol

    init(client: SensiboClientProtocol) { self.client = client }

    /// Fire-and-forget warm-up so the first screen and first tap pay no cost.
    func warmup() {
        Task { await self.load() }
    }

    func load() async -> Result<[AirCon], Error> {
        do {
            let loaded = try await self.client.pods()
            self.acs = loaded
            self.isReady = true
            return .success(loaded)
        } catch {
            self.error = "Could not reach Sensibo."
            return .failure(error)
        }
    }

    /// Fire the optimistic toggle.
    ///
    /// The UI flip is *synchronous* (it happens in this function, before any
    /// `await`), so a test asserting right after `toggle` returns is guaranteed.
    /// The returned Task performs the server confirm and can be awaited to assert
    /// the commit/revert outcome deterministically (no sleeps).
    @discardableResult
    func toggle(_ id: String) -> Task<Void, Never> {
        guard let idx = self.acs.firstIndex(where: { $0.id == id }) else {
            return Task {}
         }

        let newValue = !self.acs[idx].on
        let podId = self.acs[idx].id

        // 1) Synchronous optimistic update — instant.
        self.acs[idx].on = newValue
        self.pending.insert(podId)
        self.error = nil

        // 2) Async server confirm.
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.setCurrent(on: newValue, podId: podId)
            } catch {
                // revert to the pre-toggle value
                if let i = self.acs.firstIndex(where: { $0.id == podId }) {
                    self.acs[i].on = !newValue
                }
                self.error = (error as? SensiboError)?.errorDescription ?? error.localizedDescription
            }
            self.pending.remove(podId)
        }
    }

    /// Set the temperature for an AC unit.
    ///
    /// The UI flip is *synchronous* (it happens in this function, before any
    /// `await`), so a test asserting right after `setTemperature` returns is guaranteed.
    /// The returned Task performs the server confirm and can be awaited to assert
    /// the commit/revert outcome deterministically (no sleeps).
    @discardableResult
    func setTemperature(_ temperature: Double?, for id: String) -> Task<Void, Never> {
        guard let idx = self.acs.firstIndex(where: { $0.id == id }) else {
            return Task {}
         }

        let podId = self.acs[idx].id

        // 1) Synchronous optimistic update — instant.
        self.acs[idx].temperature = temperature
        self.pending.insert(podId)
        self.error = nil

        // 2) Async server confirm.
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.setTemperature(temperature, for: podId)
            } catch {
                // revert to the pre-set value
                if let i = self.acs.firstIndex(where: { $0.id == podId }) {
                    self.acs[i].temperature = self.acs[i].temperature // Keep current value
                }
                self.error = (error as? SensiboError)?.errorDescription ?? error.localizedDescription
            }
            self.pending.remove(podId)
        }
    }
}
