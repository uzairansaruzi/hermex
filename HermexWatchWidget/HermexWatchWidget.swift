import SwiftUI
import WidgetKit
import WatchShared

struct HermexWatchWidget: Widget {
    let kind = "HermexWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HermexWatchTimelineProvider()) { entry in
            HermexWatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Hermex")
        .description("Tap to record a voice note. Shows when a session is running or needs you.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct HermexWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HermexWatchEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: symbolName)
                    .widgetLabel(statusText)
            case .accessoryInline:
                Label(inlineText, systemImage: symbolName)
            default:
                VStack(alignment: .leading) {
                    Text(entry.snapshot?.displayName.rawValue ?? "Hermex")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                }
            }
        }
        .widgetURL(WatchComplicationLink.record)
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Starts a voice note. You can cancel before it sends.")
    }

    private var symbolName: String {
        switch entry.snapshot?.activity {
        case .running: return "ellipsis.circle"
        case .needsAttention: return "exclamationmark.circle"
        case .idle: return "checkmark.circle"
        case .unknown, nil: return "iphone.and.arrow.forward"
        }
    }

    private var statusText: String {
        switch entry.snapshot?.activity {
        case .running: return "Running"
        case .needsAttention: return "Needs you"
        case .idle: return "Ready"
        case .unknown, nil: return "Set up on iPhone"
        }
    }

    private var inlineText: String {
        if let snapshot = entry.snapshot {
            return "\(snapshot.displayName.rawValue) · \(statusText)"
        }
        return "Set up on iPhone"
    }

    private var accessibilityText: String {
        inlineText
    }
}
