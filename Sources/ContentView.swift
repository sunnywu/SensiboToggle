import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: ACController
    @ObservedObject var lightController: TapoController

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                if self.isLoading {
                    ProgressView("Loading devices...")
                        .controlSize(.small)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }

                if let error = controller.error {
                    StatusBanner(text: error)
                }

                if let error = lightController.error {
                    StatusBanner(text: error)
                }

                VStack(spacing: 6) {
                    ForEach(controller.acs) { ac in
                        ACCompactRow(
                            ac: ac,
                            pending: controller.pending.contains(ac.id),
                            toggle: { controller.toggle(ac.id) }
                        )
                    }

                    ForEach(lightController.lights) { light in
                        LightCompactRow(
                            light: light,
                            pending: lightController.pending.contains(light.id),
                            toggle: { lightController.toggle(light.id) }
                        )
                    }

                    if lightController.isReady && lightController.lights.isEmpty {
                        EmptyLightRow()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("device.dashboard")
            .navigationTitle("Sensibo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if !self.controller.isReady {
                _ = await self.controller.load()
            }
            if !self.lightController.isReady {
                _ = await self.lightController.load()
            }
        }
    }

    private var isLoading: Bool {
        !controller.isReady && controller.error == nil
    }
}

private struct ACCompactRow: View {
    let ac: AirCon
    let pending: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ac.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(ac.on ? .orange : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(ac.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(ac.on ? "Aircon on" : "Aircon off")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(ac.temperatureDisplay)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { ac.on },
                set: { _ in toggle() }
            ))
            .labelsHidden()
            .tint(ac.on ? .orange : .blue)
            .scaleEffect(0.84)
            .frame(width: 52, height: 32)
            .accessibilityIdentifier("toggle.\(ac.id)")
            .disabled(pending)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52, maxHeight: 52)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ac.row.\(ac.id)")
    }
}

private struct LightCompactRow: View {
    let light: Light
    let pending: Bool
    let toggle: () -> Void

    var body: some View {
        Button {
            if !pending {
                toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: light.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(light.on ? .yellow : .gray)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(light.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text(light.on ? "Tapo on" : "Tapo off")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("Light")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 38, alignment: .trailing)

                SwitchPill(on: light.on, tint: .yellow)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52, maxHeight: 52)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .accessibilityIdentifier("light.toggle.\(light.id)")
        .accessibilityLabel(light.displayName)
        .accessibilityValue(light.on ? "1" : "0")
    }
}

private struct SwitchPill: View {
    let on: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? tint : Color(.systemGray4))
            Circle()
                .fill(Color.white)
                .frame(width: 24, height: 24)
                .padding(4)
        }
        .frame(width: 52, height: 32)
        .overlay {
            if !on {
                Capsule()
                    .stroke(Color(.systemGray3), lineWidth: 2)
            }
        }
    }
}

private struct EmptyLightRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.gray)
                .frame(width: 24)

            Text("No Tapo light configured")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52, maxHeight: 52)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("light.empty")
    }
}

private struct StatusBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.red)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let controller = ACController(client: MockSensiboClient(seed: [
            AirCon(id: "wZnPcb29", name: "", room: "Bedroom 1", on: true, temperature: 23, mode: "heat"),
            AirCon(id: "Uevgyz7e", name: "", room: "Bedroom 2", on: false, temperature: 26, mode: "heat"),
            AirCon(id: "hz5nXQHC", name: "", room: "Living Room", on: false, temperature: 22, mode: "auto"),
            AirCon(id: "Xo5hnkKY", name: "", room: "Bedroom 3", on: false, temperature: 21, mode: "auto"),
        ]))
        let lightController = TapoController(client: MockTapoClient(seed: [
            Light(id: "Verandah", name: "Verandah", room: "Verandah", on: false),
        ]))
        return ContentView(controller: controller, lightController: lightController)
    }
}
