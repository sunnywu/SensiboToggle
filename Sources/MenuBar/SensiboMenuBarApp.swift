import SwiftUI

/// Resident macOS menu-bar front-end — the "alternative" to the home-screen widget.
///
/// It shares the exact same core as the iOS/macOS app — `ACController` plus the
/// Sensibo clients — so behaviour is identical: optimistic toggle (instant UI
/// flip, async server confirm/revert), `SENSIBO_MOCK=1` mock mode, and live mode
/// backed by `config/local.config.json`.
///
/// It is a menu-bar-only *agent* (`LSUIElement` in its Info.plist): no Dock icon,
/// it just pins a control to the menu bar so the air-con can be flipped on/off at
/// a glance without opening any window.
///
/// `MenuBarExtra` (macOS 13+) is the only macOS-only bit, which is why this entry
/// point lives in its own file and is deliberately *not* added to the iOS target.
@main
struct SensiboMenuBarApp: App {
    @StateObject private var controller: ACController
    @StateObject private var train: NSWTrainController

    init() {
        let config = Config.load()
        let controller: ACController
        let trains: NSWTrainController
        if config.mockMode {
            let mock = MockSensiboClient(seed: [
                AirCon(id: "wZnPcb29", name: "", room: "Bedroom 1", on: true, temperature: 23, mode: "heat"),
                AirCon(id: "Uevgyz7e", name: "", room: "Bedroom 2", on: false, temperature: 26, mode: "heat"),
                AirCon(id: "hz5nXQHC", name: "", room: "Living Room", on: false, temperature: 22, mode: "auto"),
                AirCon(id: "Xo5hnkKY", name: "", room: "Bedroom 3", on: false, temperature: 21, mode: "auto"),
              ])
            controller = ACController(client: mock, pollIntervalSeconds: config.pollIntervalSeconds)
            trains = NSWTrainController(config: config.nswTrain,
                                        client: MockNSWTrainClient(seed: NSWTrainController.demoSeed()))
           } else {
            // Using the authentic Sensibo client with the API key from configuration
            let client = SensiboClient(baseURL: config.baseURL, apiKey: config.apiKey)
            controller = ACController(client: client, pollIntervalSeconds: config.pollIntervalSeconds)
            trains = NSWTrainController(config: config.nswTrain,
                                        client: NSWTrainClient(apiKey: config.nswTrain.apiKey))
          }
        _controller = StateObject(wrappedValue: controller)
            _train = StateObject(wrappedValue: trains)

        // Preload before the user opens the menu: fetch device state at launch so
        // the first popover is instant instead of loading on the first click.
        controller.warmup()
        trains.warmup()
         // Repeat the poll at the configured interval when the banner is configured.
         if trains.config.isConfigured { trains.startScheduler() }
        }

    var body: some Scene {
        MenuBarExtra {
            SensiboMenuBarView(controller: controller, train: train)
        } label: {
            // The bar icon itself reflects state so on/off is visible at a glance.
            Image(systemName: controller.acs.contains(where: { $0.on }) ? "flame.fill" : "flame")
        }
        .menuBarExtraStyle(.window)
    }
}
