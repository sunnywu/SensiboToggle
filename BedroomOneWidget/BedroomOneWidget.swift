import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private struct BedroomOneEntry: TimelineEntry {
    let date: Date
    let state: BedroomOneState
}

private struct BedroomOneTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BedroomOneEntry {
        BedroomOneEntry(date: .now, state: BedroomOneState(isOn: false, temperature: 23, error: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (BedroomOneEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            completion(await Self.loadEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BedroomOneEntry>) -> Void) {
        Task {
            let entry = await Self.loadEntry()
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
        }
    }

    private static func loadEntry() async -> BedroomOneEntry {
        let config = WidgetConfigLoader.load()
        if config.mockMode {
            return BedroomOneEntry(date: .now, state: BedroomOneState(isOn: false, temperature: 23, error: nil))
        }
        do {
            let state = try await BedroomOneSensiboClient(config: config).bedroomOneState()
            return BedroomOneEntry(date: .now, state: state)
        } catch {
            return BedroomOneEntry(date: .now, state: BedroomOneState(isOn: nil, temperature: nil, error: "Unavailable"))
        }
    }
}

private struct BedroomOneToggleWidgetView: View {
    let entry: BedroomOneTimelineProvider.Entry

    var body: some View {
        Button(intent: ToggleBedroomOneIntent()) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: entry.state.isOn == true ? "snowflake.circle.fill" : "snowflake.circle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(entry.state.isOn == true ? .white : .cyan)
                    Spacer()
                    statusBadge
                }

                Spacer(minLength: 8)

                Text("Bedroom 1")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: entry.state.isOn == true
                    ? [Color(red: 0.03, green: 0.44, blue: 0.68), Color(red: 0.00, green: 0.18, blue: 0.32)]
                    : [Color(red: 0.10, green: 0.13, blue: 0.18), Color(red: 0.02, green: 0.04, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2.weight(.bold))
            .foregroundStyle(entry.state.isOn == true ? Color(red: 0.02, green: 0.16, blue: 0.28) : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(entry.state.isOn == true ? .white : .white.opacity(0.18))
            .clipShape(Capsule())
    }

    private var statusText: String {
        if entry.state.error != nil {
            return "ERROR"
        }
        guard let isOn = entry.state.isOn else {
            return "..."
        }
        return isOn ? "ON" : "OFF"
    }

    private var subtitle: String {
        if entry.state.error != nil {
            return "Tap to retry"
        }
        if let temperature = entry.state.temperature {
            return "Tap to turn \(entry.state.isOn == true ? "off" : "on") - \(Int(temperature)) deg"
        }
        return "Tap to turn \(entry.state.isOn == true ? "off" : "on")"
    }
}

struct BedroomOneToggleWidget: Widget {
    static let kind = bedroomOneWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: BedroomOneTimelineProvider()) { entry in
            BedroomOneToggleWidgetView(entry: entry)
        }
        .configurationDisplayName("Bedroom 1 AC")
        .description("Toggle the Bedroom 1 air conditioner.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

@main
struct BedroomOneWidgetBundle: WidgetBundle {
    var body: some Widget {
        BedroomOneToggleWidget()
    }
}
