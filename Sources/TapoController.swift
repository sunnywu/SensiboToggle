import Foundation
import Combine

/// Drives the Tapo light UI the same way `ACController` drives the Sensibo UI:
/// optimistic flip first, async server confirm / revert. Holds a
/// `TapoClientProtocol` so it can be unit-tested with `MockTapoClient` and run in
/// mock mode with zero network.
@MainActor
final class TapoController: ObservableObject {
    @Published private(set) var lights: [Light] = []
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var error: String? = nil
    @Published private(set) var isReady = false

    let client: TapoClientProtocol

    init(client: TapoClientProtocol) { self.client = client }

     /// Fire-and-forget warm-up so the first screen and first tap pay no cost.
    func warmup() {
        Task { await self.load() }
     }

    func load() async -> Result<[Light], Error> {
        do {
            let loaded = try await self.client.load()
            self.lights = loaded
            self.isReady = true
            return .success(loaded)
         } catch {
            self.error = "Could not reach Tapo."
            return .failure(error)
         }
     }

     /// Fire the optimistic toggle for a device (keyed by its `Light.id`, which
     /// equals the configured device name).
     ///
     /// The UI flip is *synchronous* (before any `await`), so the returned Task
     /// performs the async KLAP confirm and can be awaited to assert the
     /// commit/revert outcome deterministically.
    @discardableResult
    func toggle(_ device: String) -> Task<Void, Never> {
        guard let idx = self.lights.firstIndex(where: { $0.id == device }) else {
            return Task {}
         }

        let newValue = !self.lights[idx].on
        let deviceId = self.lights[idx].id

         // 1) Synchronous optimistic update - instant.
        self.lights[idx].on = newValue
        self.pending.insert(deviceId)
        self.error = nil

         // 2) Async server confirm.
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.set(on: newValue, device: deviceId)
             } catch {
                 // Revert to the pre-toggle value.
                if let i = self.lights.firstIndex(where: { $0.id == deviceId }) {
                    self.lights[i].on = !newValue
                 }
                self.error = (error as? TapoError)?.errorDescription ?? error.localizedDescription
             }
            self.pending.remove(deviceId)
         }
     }
}
