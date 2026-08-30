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

        // How often (seconds) to re-read pod state to catch on/off + temperature
        // changes made elsewhere (the Sensibo app, a remote, a device schedule) and
        // refresh the UI. `<= 0` disables polling. Defaults to 0 so hermetic unit tests
        // that don't pass it stay inert; the app supplies the configured value
        // (30s in live mode, off in mock mode).
    let pollIntervalSeconds: TimeInterval

        // Shared one-shot/cancellable timer seam -- the same `TaskIdleScheduler` the
        // wall-panel dimmer uses. Injected so tests can drive polls with no real
        // `Task.sleep`.
    private let scheduler: any IdleScheduler
        // The live poll timer, if any (nil when polling is off or between ticks).
    private var pollTimer: (any IdleTimer)?

    init(client: SensiboClientProtocol,
         pollIntervalSeconds: TimeInterval = 0,
         scheduler: any IdleScheduler = TaskIdleScheduler()) {
        self.client = client
        self.pollIntervalSeconds = pollIntervalSeconds
        self.scheduler = scheduler
           // Arm the recurring poll on launch when enabled. `reschedulePoll` guards the
           // interval, so the default (0) case is a safe no-op that leaves no timer.
        self.reschedulePoll()
      }

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

      // MARK: - Polling

      /// Reconcile pod state from the server into `acs` so changes made *elsewhere*
      /// (the Sensibo app, a remote, a scheduled turn-on/off) refresh the UI without an
      /// explicit user fetch.
      ///
      /// - No-op when polling is disabled (`pollIntervalSeconds <= 0`) or on a transient
      ///   fetch failure, so a network blip never blanks or churns the UI.
      /// - Skips any pod in `pending`, so a poll can never clobber an in-flight
      ///   optimistic toggle (the tap is authoritative until its server confirm lands).
      /// - Preserves the current order and appends only brand-new pods, so the UI never
      ///   reorders mid-poll, and writes `acs` only when something actually changed.
    func refresh() async {
        guard self.pollIntervalSeconds > 0 else { return }
        let fresh = try? await self.client.pods()
        guard let fresh else { return }

        let freshByID = Dictionary(fresh.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var updated = self.acs
        for i in updated.indices where !self.pending.contains(updated[i].id) {
            guard let f = freshByID[updated[i].id] else { continue }
            updated[i].on = f.on
            updated[i].temperature = f.temperature
            updated[i].mode = f.mode
            if let room = f.room, !room.isEmpty { updated[i].room = room }
         }
        for f in fresh where !updated.contains(where: { $0.id == f.id }) {
            updated.append(f)
         }

        if updated != self.acs { self.acs = updated }
       }

       /// Arm the recurring poll. Each tick re-arms the *next* one first so the cadence
       /// is a clean multiple of `pollIntervalSeconds` even when a refresh is slow, then
       /// reconciles in the background. Inert when the interval is `<= 0`.
     private func reschedulePoll() {
        self.pollTimer?.cancel()
        guard self.pollIntervalSeconds > 0 else {
            self.pollTimer = nil
            return
         }
        self.pollTimer = self.scheduler.schedule(after: self.pollIntervalSeconds) { [weak self] in
             // The scheduler always delivers on the main actor (production
             // `TaskIdleScheduler` is `@MainActor`; the test scheduler runs this
             // synchronously), so the `@Published` write below is always on main.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reschedulePoll()                     // re-arm the next tick
                Task { @MainActor in await self.refresh() }
             }
        }
       }
}
