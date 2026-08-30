import SwiftUI

/// Compact popover shown under the menu-bar icon: one toggle row per Sensibo AC.
///
/// It reuses the *same* optimistic toggle binding as `ContentView`, so a flip is
/// instant and the server confirm/rollback runs in the background. Sized for the
/// menu bar so several units stay visible without any window.
struct SensiboMenuBarView: View {
    @ObservedObject var controller: ACController
    @ObservedObject var train: NSWTrainController

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
            trainSection
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

     @ViewBuilder
      private var trainSection: some View {
        if case .hidden = self.train.state {
            EmptyView()                          // disabled: original layout, no extra divider
        } else {
            VStack(spacing: 0) {
                Divider()
                trainBanner
                 }
           }
         }

       @ViewBuilder
    private var trainBanner: some View {
        switch self.train.state {
        case .hidden:
            EmptyView()
        case .loading:
            Text("Loading train times…")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        case .empty:
            Text("No Wynyard train in next 15 min")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        case .stale:
            Text("Train times unavailable")
                .font(.caption)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)
        case .next(let rows):
            VStack(alignment: .leading, spacing: 3) {
                Text("Next trains")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    MenuTrainDepartureLine(row: row)
                }
            }
        }
    }

}

private struct MenuTrainDepartureLine: View {
    let row: NSWTrainDisplayRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.leadMinutesText)
                .font(.body.weight(.bold))
                .monospacedDigit()
                .foregroundColor(row.isImminent ? .orange : .primary)
                .frame(width: 58, alignment: .leading)
            Text("🚃")
            Text(row.destination)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.clockText)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }
}
