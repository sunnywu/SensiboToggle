import SwiftUI

struct ContentView: View {
     @ObservedObject var controller: ACController
    @ObservedObject var lightController: TapoController
      // Idle-dimming controller. Defaults to an inert instance so previews compile
      // without wiring; the app injects the real one from config.
    @ObservedObject var idle: IdleDimmingController = IdleDimmingController(enabled: false)
       // Next-train banner. Inert default (hidden) so previews compile without
        // wiring; the app injects the real controller with the client + config.
       @ObservedObject var train: NSWTrainController = NSWTrainController(config: .default, client: MockNSWTrainClient(seed: []))
     @Environment(\.scenePhase) private var scenePhase

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
                                        toggle: {
                                        idle.registerActivity()
                                         controller.toggle(ac.id)
                                          })
                           }

                          ForEach(lightController.lights) { light in
                                       LightCompactRow(
                                              light: light,
                                             pending: lightController.pending.contains(light.id),
                                              toggle: {
                                              idle.registerActivity()
                                              lightController.toggle(light.id)
                                               })
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
          // --- Wall-panel / kiosk layer --------------------------------
          // When `idle.isDimmed` a blank black view covers everything and any
          // touch wakes it. When awake, `.simultaneousGesture` lets *any* tap
          // (empty space or on a control) reset the idle countdown. This whole
          // block is inert when wall-panel mode is off.
          .overlay {
              if idle.isDimmed {
                       WallBlankOverlay()
                              .contentShape(Rectangle())
                                .onTapGesture { idle.registerActivity() }
                                .accessibilityIdentifier("wall.blank.overlay")
                                .accessibilityLabel("Wake wall panel")
             }
          }
          .simultaneousGesture(TapGesture().onEnded { idle.registerActivity() })
          .statusBarHidden(idle.enabled)   // deprecated, still honoured; truly blank wall
                 .safeAreaInset(edge: .bottom) {
                      self.trainFooter
                  }
          .onChange(of: scenePhase) { _, phase in
              switch phase {
              case .active:
                      idle.registerActivity()
              default:
                       idle.sceneInactive()
             }
          }
          }

    private var isLoading: Bool {
             !controller.isReady && controller.error == nil
      }
        // --- Bottom-pinned next-train banner -------------------------------
        // Always visible via `.safeAreaInset`, so the user sees the next Wynyard
        // trains without scrolling. Hidden entirely when the banner isn't configured.
     @ViewBuilder
    private var trainFooter: some View {
        switch self.train.state {
        case .hidden:
            EmptyView()
        case .loading:
            Text("Loading train times…")
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 14)
                  .padding(.vertical, 6)
                  .padding(.bottom, 8)
        case .empty:
            Text("No Wynyard train in next 15 min")
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 14)
                  .padding(.vertical, 6)
                  .padding(.bottom, 8)
        case .stale:
            Text("Train times unavailable")
                  .font(.subheadline)
                  .foregroundColor(.orange)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 14)
                  .padding(.vertical, 6)
                  .padding(.bottom, 8)
        case .next(let rows):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    TrainDepartureLine(row: row)
                }
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 6)
              .padding(.bottom, 8)
          }
      }

}

private struct TrainDepartureLine: View {
    let row: NSWTrainDisplayRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.leadMinutesText)
                .font(.body.weight(.bold))
                .monospacedDigit()
                .foregroundColor(row.isImminent ? .orange : .primary)
                .frame(width: 64, alignment: .leading)
            Text("🚃")
                .font(.body)
            Text(row.destination)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(row.clockText)
                .font(.body)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-bleed opaque black view shown while the panel is idle. The controller
/// also lowers hardware brightness, so wall mode is both visually blank and
/// gentler on the LCD backlight.
private struct WallBlankOverlay: View {
        var body: some View {
             Color.black
                     .ignoresSafeArea()
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
               // Inert idle controller: previews don't blank.
        let idle = IdleDimmingController(enabled: false)
        let train = NSWTrainController(config: NSWTrainConfig(apiKey: "mock", enabled: true),
                                    client: MockNSWTrainClient(seed: [NSWTrainArrival(destination: "Wynyard", departure: Date().addingTimeInterval(7 * 60))]))
        return ContentView(controller: controller, lightController: lightController, idle: idle, train: train)
   }
}
