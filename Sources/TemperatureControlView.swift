import SwiftUI

struct TemperatureControlView: View {
    let ac: AirCon
    let controller: ACController
    @State private var temperature: Double?

    init(ac: AirCon, controller: ACController) {
        self.ac = ac
        self.controller = controller
        self._temperature = State(initialValue: ac.temperature ?? 20.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Temperature")
                    .font(.headline)

                Spacer()

                if let temp = temperature {
                    Text("\(Int(temp))°")
                        .font(.title3)
                        .fontWeight(.medium)
                } else {
                    Text("-°")
                        .font(.title3)
                        .fontWeight(.medium)
                }
            }

            Slider(
                value: Binding(
                    get: { temperature ?? 20.0 },
                    set: { newValue in
                        temperature = newValue
                        // Update the controller with the new temperature (will be sent to API)
                        controller.setTemperature(newValue, for: ac.id)
                    }
                ),
                in: 16...30,
                step: 0.5,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        // When user stops sliding, send the final temperature value
                        controller.setTemperature(temperature, for: ac.id)
                    }
                }
            )
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button("16°") {
                    temperature = 16.0
                    controller.setTemperature(16.0, for: ac.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("20°") {
                    temperature = 20.0
                    controller.setTemperature(20.0, for: ac.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("24°") {
                    temperature = 24.0
                    controller.setTemperature(24.0, for: ac.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("28°") {
                    temperature = 28.0
                    controller.setTemperature(28.0, for: ac.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}