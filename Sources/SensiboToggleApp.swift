import SwiftUI

@main
struct SensiboToggleApp: App {
     @StateObject private var controller: ACController
     @StateObject private var lightController: TapoController

    init() {
        let config = Config.load()
        let ac: ACController
        let lights: TapoController
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
            ac = ACController(client: mock)
            lights = TapoController(client: mockLights)
           } else {
             // Using the authentic Sensibo client with the API key from configuration
            let client = SensiboClient(baseURL: config.baseURL, apiKey: config.apiKey)
              // The Verandah light speaks KLAP over the local network to its IP from
              // config/local.config.json. No devices configured -> the section is empty.
            let tapo = KLAPTapoClient(email: config.tapoEmail,
                                     password: config.tapoPassword,
                                     devices: config.tapoDevices)
            ac = ACController(client: client)
            lights = TapoController(client: tapo)
           }

        _controller = StateObject(wrappedValue: ac)
        _lightController = StateObject(wrappedValue: lights)

         // Preload light state at launch so the first screen is instant.
        lights.warmup()
         }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: self.controller, lightController: self.lightController)
             }
             }
         }
