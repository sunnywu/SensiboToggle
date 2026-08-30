import Foundation
import SwiftUI

// MARK: - The next-train banner controller.
//
// `@MainActor` + `ObservableObject`, poll-driven (mirrors `ACController` + `TapoController`:
// state is `@Published`, a background timer drives refresh, and the UI just reflects it).
// The heavy lifting — next-2 selection, minute formatting, and fallback city matching
// — lives in the pure functions in `NSWTrainModels.swift`, so this file is just the
// state machine that turns "polls come and go" into one of `.hidden / .loading / .next
// / .empty / .stale`.
//
// Invariants:
//      - **Never touch a real train or the AC.** This only *reads* TfNSW.
//      - On a transient network failure we **keep the last good value** (the view is
//        unchanged) until the value is more than `staleAfterSeconds` old, then show
//         "Train times unavailable" (`.stale`).
//      - The value never ticks between polls — it refreshes on each poll only.
@MainActor
final class NSWTrainController: ObservableObject {

      // MARK: published UI state

    @Published var state: NSWTrainState = .hidden
    @Published var lastError: String? = nil
       /// True once a successful poll has run, so the view can drop the "loading" hint.
    @Published var isReady = false

       // MARK: dependencies

    let config: NSWTrainConfig
    private let client: any NSWTrainClientProtocol
    private let scheduler: IdleScheduler
      /// Injectable clock so tests can advance time deterministically.
    private var nowSupplier: () -> Date = { Date() }

       // MARK: resolved + last-good tracking

    private var stopID: String = ""                // resolved exactly once at startup
    private var hasResolvedStop = false
    private var destinationStopID: String = ""     // non-empty → use TfNSW trip endpoint
    private var hasEverSucceeded = false
    private var lastGoodDate: Date? = nil
    private var pollTimer: (any IdleTimer)? = nil
    private var inFlight = false

    init(config: NSWTrainConfig,
         client: any NSWTrainClientProtocol,
         scheduler: IdleScheduler = TaskIdleScheduler()) {
        self.config = config
        self.client = client
        self.scheduler = scheduler
          // Not configured at all → stay hidden and never poll.
        self.state = .hidden
         }

       // MARK: injection seams (tests)

     /// Override the clock. Tests pin this to a fixed date so minute + stale math is
    /// deterministic and hermetic.
    func setNow(_ now: @escaping @MainActor () -> Date) {
        self.nowSupplier = now
         }

        /// Pin the stop id so the `stop_finder` lookup is skipped (production uses the
        /// config's `stopID`, if set; otherwise stop_finder resolves it at first poll).
     func setStopID(_ id: String) {
        guard !id.isEmpty else { return }
        self.stopID = id
        self.hasResolvedStop = true
        }

       // MARK: lifecycle

        /// Fire-and-forget warm-up: resolve the station and do one poll so the first
       /// screen has data as soon as possible.
    func warmup() {
        guard self.config.isConfigured else { self.state = .hidden; return }
        Task { await self.poll() }
        }

         /// Start repeating polls at the configured interval. A 0 interval is a safe
      /// no-op that leaves no timer — the same "disabled by default" behaviour as Sensibo.
      @discardableResult
     func startScheduler() -> IdleTimer? {
        guard self.config.isConfigured else { self.state = .hidden; return nil }
        self.reschedulePoll()
        return self.pollTimer
         }

    func stopScheduler() {
        self.pollTimer?.cancel()
        self.pollTimer = nil
        }

        /// Manual refresh (e.g. a user "Refresh" tap in the menu bar).
      @discardableResult
    func refresh() -> Task<Void, Never> {
        guard self.config.isConfigured else { return Task {} }
        return Task { @MainActor [weak self] in await self?.poll() }
         }

       // MARK: polling internals

     /// Arm the recurring poll. Each tick re-arms the *next* one first so the cadence is
      /// a clean multiple of `pollIntervalSeconds` even when a refresh is slow, then runs
      /// `poll()`. Inert when the interval is `<= 0`.
     private func reschedulePoll() {
        self.pollTimer?.cancel()
        guard self.config.pollIntervalSeconds > 0 else {
            self.pollTimer = nil
            return
            }
        self.pollTimer = self.scheduler.schedule(after: self.config.pollIntervalSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                 // Re-arm first (mirrors `ACController`), then refresh.
                self.reschedulePoll()
                Task { @MainActor in await self.poll() }
                }
             }
          }

        /// One poll cycle. Overlapping calls are skipped so a slow poll never stacks.
     func poll() async {
        guard !self.inFlight else { return }
        self.inFlight = true
        defer { self.inFlight = false }

        let now = self.nowSupplier()

         // Resolve the stop id exactly once: config override, else stop_finder, else fallback.
        if !self.hasResolvedStop {
            await self.resolveStop()
            self.hasResolvedStop = true
             }

        do {
            let arrivals: [NSWTrainArrival]
            let rows: [NSWTrainDisplayRow]
            if !self.destinationStopID.isEmpty {
                arrivals = try await self.client.journeyDepartures(
                    originStopID: self.stopID,
                    destinationStopID: self.destinationStopID)
                rows = NSWTrainSelection.displayRows(from: arrivals, now: now)
             } else {
                arrivals = try await self.client.departures(stopID: self.stopID)
                rows = NSWTrainSelection.displayRows(
                    from: arrivals,
                    allowlist: self.config.destinationAllowlist,
                    now: now)
             }
            self.hasEverSucceeded = true
            self.lastGoodDate = now
            self.lastError = nil
            self.isReady = true
             // Rows are computed at `now`, so "in N min" refreshes on every poll.
            self.state = rows.isEmpty ? .empty : .next(rows)
            } catch {
            self.lastError = (error as? NSWTrainError)?.localizedDescription
                       ?? (error as? SensiboError)?.errorDescription
                       ?? error.localizedDescription
              // No value yet → keep the "loading" hint (still trying for the first value).
            if !self.hasEverSucceeded {
                self.state = .loading
             } else if let lastGood = self.lastGoodDate,
                       now.timeIntervalSince(lastGood) > self.config.staleAfterSeconds {
                 // Past the stale threshold → drop to "unavailable". Up until this point the
                 // last good value was left in place (no change to `state`).
                self.state = .stale
              }
              // Otherwise: keep the last good value unchanged.
             }
        }

    private func resolveStop() async {
        if !self.config.stopID.isEmpty {
            self.stopID = self.config.stopID
             } else {
            let resolved = try? await self.client.resolveStopID(name: self.config.originStation)
            self.stopID = resolved ?? NSWTrainConfig.ashfieldStopID
            }
        self.destinationStopID = self.config.destinationStopID
        }

        /// A near-future Ashfield → Wynyard seed for the *mock-mode* banner. Returned
          /// departures are absolute, computed relative to "now" at call time.
      @MainActor
    static func demoSeed() -> [NSWTrainArrival] {
        let now = Date()
        return [
            NSWTrainArrival(destination: "Lindfield", departure: now.addingTimeInterval(7 * 60)),
            NSWTrainArrival(destination: "Hornsby via Gordon", departure: now.addingTimeInterval(14 * 60)),
            ]
          }

}
