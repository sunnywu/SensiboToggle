import SwiftUI

/// Compact popover shown under the menu-bar icon: one toggle row per Sensibo AC.
///
/// It reuses the *same* optimistic toggle binding as `ContentView`, so a flip is
/// instant and the server confirm/rollback runs in the background. Sized for the
/// menu bar so several units stay visible without any window.
struct SensiboMenuBarView: View {
    @ObservedObject var controller: ACController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "airconditioner")
                Text("Sensibo").font(.headline)
                Spacer()
                if !controller.pending.isEmpty {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            Divider()

            content
            Divider()

            Button("Refresh") {
                Task { await controller.load() }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if let error = controller.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280)
        .task {
            if !controller.isReady {
                _ = await controller.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !controller.isReady && controller.error == nil {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if controller.acs.isEmpty {
            Text("No devices")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else {
            ForEach(controller.acs) { ac in
                HStack {
                    Button {
                        controller.toggle(ac.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ac.symbol)
                                 .foregroundColor(ac.on ? .orange : .blue)
                            Text(ac.displayName)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.pending.contains(ac.id))
                    
                    Spacer()
                    Text(ac.temperatureDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("", isOn: Binding(
                        get: { ac.on },
                        set: { _ in controller.toggle(ac.id) }
                    ))
                    .labelsHidden()
                    .tint(ac.on ? .orange : .blue)
                    .disabled(controller.pending.contains(ac.id))
                }
                .padding(.vertical, 2)
            }
        }
    }
}
