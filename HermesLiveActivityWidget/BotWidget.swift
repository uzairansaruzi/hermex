import AppIntents
import SwiftUI
import WidgetKit

struct BotWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BotWidgetSnapshot.widgetKind, intent: BotWidgetConfigurationIntent.self,
                               provider: BotWidgetTimeline()) { entry in
            BotWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.slots.count == 1 ? entry.slots[0].destination : nil)
        }
        .configurationDisplayName("Bot")
        .description("Opens a bot's chat.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BotWidgetEntry: TimelineEntry {
    enum Slot: Equatable {
        case empty
        case unavailable
        case bot(title: String, light: URL?, dark: URL?, destination: BotWidgetDestination)

        var destination: URL? {
            if case .bot(_, _, _, let destination) = self { destination.url } else { nil }
        }
    }

    let date: Date
    let slots: [Slot]

    init(date: Date, configuration: BotWidgetConfigurationIntent, family: WidgetFamily,
         file: BotWidgetSnapshotFile? = .shared) {
        self.date = date
        let snapshot = file?.read() ?? BotWidgetSnapshot()
        func slot(_ entity: BotWidgetEntity?) -> Slot {
            guard let entity else { return .empty }
            guard let file, let target = entity.destination,
                  let found = snapshot.bot(serverKey: target.serverKey, profile: target.profile) else { return .unavailable }
            func existing(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }
            return .bot(title: found.title, light: existing(file.avatarURL(found.avatar, dark: false)),
                        dark: existing(file.avatarURL(found.avatar, dark: true)), destination: target)
        }
        let count = Self.slotCount(family)
        guard count > 1 else { slots = [slot(configuration.bot)]; return }
        let chosen = (configuration.bots ?? []).prefix(count).map { slot($0) }
        slots = chosen + Array(repeating: .empty, count: count - chosen.count)
    }

    init(date: Date, slots: [Slot]) {
        self.date = date
        self.slots = slots
    }

    static func slotCount(_ family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 4
        case .systemLarge: 8
        default: 1
        }
    }
}

struct BotWidgetTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BotWidgetEntry {
        let hermes = BotWidgetEntry.Slot.bot(title: String(localized: "Hermes"), light: nil, dark: nil,
                                             destination: BotWidgetDestination(serverKey: "", profile: ""))
        return BotWidgetEntry(date: Date(), slots: Array(repeating: hermes, count: BotWidgetEntry.slotCount(context.family)))
    }

    func snapshot(for configuration: BotWidgetConfigurationIntent, in context: Context) async -> BotWidgetEntry {
        let entry = BotWidgetEntry(date: Date(), configuration: configuration, family: context.family)
        return context.isPreview && entry.slots.allSatisfy({ $0 == .empty }) ? placeholder(in: context) : entry
    }

    func timeline(for configuration: BotWidgetConfigurationIntent, in context: Context) async -> Timeline<BotWidgetEntry> {
        let entry = BotWidgetEntry(date: Date(), configuration: configuration, family: context.family)
        return Timeline(entries: [entry], policy: entry.slots.contains(.unavailable) ? .after(entry.date.addingTimeInterval(60 * 60)) : .never)
    }
}

private struct BotWidgetView: View {
    let entry: BotWidgetEntry

    var body: some View {
        if entry.slots.count == 1 {
            BotWidgetSlotView(slot: entry.slots[0], faceSize: 76, isSingle: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Grid(horizontalSpacing: 4, verticalSpacing: 0) {
                ForEach(0..<entry.slots.count / 4, id: \.self) { row in
                    GridRow {
                        ForEach(row * 4..<row * 4 + 4, id: \.self) { index in
                            cell(entry.slots[index])
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ slot: BotWidgetEntry.Slot) -> some View {
        let view = BotWidgetSlotView(slot: slot, faceSize: 58, isSingle: false).frame(maxWidth: .infinity)
        if let url = slot.destination { Link(destination: url) { view } } else { view }
    }
}

private struct BotWidgetSlotView: View {
    @Environment(\.colorScheme) private var colorScheme
    let slot: BotWidgetEntry.Slot
    let faceSize: CGFloat
    let isSingle: Bool

    var body: some View {
        VStack(spacing: isSingle ? 8 : 6) {
            face
                .frame(width: faceSize, height: faceSize)
            VStack(spacing: 2) {
                Text(title)
                    .font(isSingle ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(isSingle ? 2 : 1)
                    .minimumScaleFactor(0.8)
                if isSingle, let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
        }
        .opacity(slot.destination == nil && !isSingle ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var face: some View {
        switch slot {
        case .bot(_, let light, let dark, _):
            if let url = colorScheme == .dark ? dark : light, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .scaledToFit()
            } else {
                BotWidgetPlainFace(isFlat: false)
            }
        case .unavailable:
            BotWidgetPlainFace(isFlat: true)
        case .empty:
            ZStack {
                Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: faceSize / 25, dash: [faceSize / 11, faceSize / 15]))
                Image(systemName: "plus")
                    .font(.system(size: faceSize / 3, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(faceSize / 19)
        }
    }

    private var title: String {
        switch slot {
        case .bot(let title, _, _, _): title
        case .unavailable: isSingle ? String(localized: "Bot unavailable") : String(localized: "Unavailable")
        case .empty: isSingle ? String(localized: "Choose a bot") : String(localized: "Add a bot")
        }
    }

    private var subtitle: String? {
        switch slot {
        case .bot: nil
        case .unavailable: String(localized: "Opens Hermex")
        case .empty: String(localized: "Touch and hold to edit")
        }
    }

    private var accessibilityLabel: String {
        switch slot {
        case .bot(let title, _, _, _): String(localized: "\(title), opens chat")
        case .unavailable, .empty: [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

private struct BotWidgetPlainFace: View {
    let isFlat: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width
            ZStack {
                Circle().fill(.quaternary)
                HStack(spacing: size * 0.12) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(.secondary)
                            .frame(width: size * (isFlat ? 0.13 : 0.09), height: size * (isFlat ? 0.05 : 0.21))
                    }
                }
            }
        }
    }
}
