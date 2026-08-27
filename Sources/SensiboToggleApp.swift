import SwiftUI

@main
struct SensiboToggleApp: App {
    @StateObject private var controller: ACController

    init() {
        let config = Config.load()
        if config.mockMode {
            let mock = MockSensiboClient(seed: [
                AirCon(id: "wZnPcb29", name: "", room: "Bedroom 1", on: true, temperature: 23, mode: "heat"),
                AirCon(id: "Uevgyz7e", name: "", room: "Bedroom 2", on: false, temperature: 26, mode: "heat"),
                AirCon(id: "hz5nXQHC", name: "", room: "Living Room", on: false, temperature: 22, mode: "auto"),
                AirCon(id: "Xo5hnkKY", name: "", room: "Bedroom 3", on: false, temperature: 21, mode: "auto"),
             ])
            _controller = StateObject(wrappedValue: ACController(client: mock))
          } else {
            // Using the authentic Sensibo client with the API key from configuration
            let client = SensiboClient(baseURL: config.baseURL, apiKey: config.apiKey)
            _controller = StateObject(wrappedValue: ACController(client: client))
         }
       }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: self.controller)
          }
        }
    }
