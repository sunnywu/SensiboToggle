import SwiftUI
import UIKit

/// Flips the one OS switch the wall-panel mode needs: keep the screen awake so
/// Guided Access never drops to the lock screen. Screen blanking and hardware
/// brightness reduction are handled by `IdleDimmingController`; this only stops
/// the device from sleeping on its own.
private final class KioskAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = Config.load().wallPanelEnabled
        return true
      }
  }

@main
struct SensiboToggleApp: App {
      @StateObject private var controller: ACController
      @StateObject private var lightController: TapoController
      @StateObject private var idle: IdleDimmingController
         @StateObject private var train: NSWTrainController
      // Disables the OS auto-lock while in wall-panel mode (see `KioskAppDelegate`).
   @UIApplicationDelegateAdaptor(KioskAppDelegate.self) private var appDelegate

    init() {
        let config = Config.load()
        let ac: ACController
        let lights: TapoController
        let trains: NSWTrainController
        if config.mockMode {
            let mock = MockSensiboClient(seed: [
                AirCon(id: "wZnPcb29", name: "", room: "Bedroom 1", on: true, temperature: 23, mode: "heat"),
                AirCon(id: "Uevgyz7e", name: "", room: "Bedroom 2", on: false, temperature: 26, mode: "heat"),
                AirCon(id: "hz5nXQHC", name: "", room: "Living Room", on: false, temperature: 22, mode: "auto"),
                AirCon(id: "Xo5hnkKY", name: "", room: "Bedroom 3", on: false, temperature: 21, mode: "auto"),
               ])
              // In mock mode the Verandah light lives in-memory so the whole toggle
              // flow can be demonstrated with zero network / no real AC or bulb.
            let mockLights = MockTapoClient(seed: [
                Light(id: "Verandah", name: "Verandah", room: "Verandah", on: false),
               ])
            ac = ACController(client: mock, pollIntervalSeconds: config.pollIntervalSeconds)
            lights = TapoController(client: mockLights)
            // In mock mode the train banner is seeded in-memory so the footer
            // can be demoed with zero network. City-match + next-2 selection still
            // run over the seed, so the outbound row proves the filter works.
            trains = NSWTrainController(config: config.nswTrain,
                                        client: MockNSWTrainClient(seed: NSWTrainController.demoSeed()))
            } else {
              // Using the authentic Sensibo client with the API key from configuration
            let client = SensiboClient(baseURL: config.baseURL, apiKey: config.apiKey)
               // The Verandah light speaks KLAP over the local network to its IP from
               // config/local.config.json. No devices configured -> the section is empty.
            let tapo = KLAPTapoClient(email: config.tapoEmail,
                                     password: config.tapoPassword,
                                     devices: config.tapoDevices)
            ac = ACController(client: client, pollIntervalSeconds: config.pollIntervalSeconds)
            lights = TapoController(client: tapo)
            // Live TfNSW next-train feed, authenticated with `nswTrain.apiKey`
            // (Authorization: apikey ...). No key / disabled -> hidden, never polls.
            trains = NSWTrainController(config: config.nswTrain,
                                        client: NSWTrainClient(apiKey: config.nswTrain.apiKey))
            }

         _controller = StateObject(wrappedValue: ac)
         _lightController = StateObject(wrappedValue: lights)
            _train = StateObject(wrappedValue: trains)

          // Wall-panel / kiosk mode: keep the screen awake and blanket it in black
          // after `wallPanelIdleSeconds` of no movement, waking on any touch.
          // Inert (no behaviour change) when the mode is off.
        let dimmer = IdleDimmingController(enabled: config.wallPanelEnabled,
                                            idleDelay: config.wallPanelIdleSeconds)
        _idle = StateObject(wrappedValue: dimmer)

          // Preload light state at launch so the first screen is instant.
        lights.warmup()
          }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: self.controller,
                        lightController: self.lightController,
                        idle: self.idle,
                        train: self.train)
               .task {
                self.train.warmup()
                  if self.train.config.isConfigured { self.train.startScheduler() }
               }
              }
              }
          }
