import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Profile cache (reads the same app-group store the main app writes)

private enum HermexWidgetProfileCache {
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String
            ?? "group.com.uzairansar.hermesmobile"
    }

    private static let storageKey = "cachedProfileEntities.v2"

    struct Record: Codable {
        let id: String
        let name: String
        let subtitle: String?
    }

    static func loadAll() -> [Record] {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records
    }
}

// MARK: - Profile entity (widget-local; mirrors ProfileEntity in the main target)

struct HermexProfileEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
    static var defaultQuery = HermexProfileEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct HermexProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HermexProfileEntity] {
        let set = Set(identifiers)
        return HermexWidgetProfileCache.loadAll()
            .filter { set.contains($0.id) }
            .map { HermexProfileEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [HermexProfileEntity] {
        let cached = HermexWidgetProfileCache.loadAll()
            .map { HermexProfileEntity(id: $0.id, name: $0.name) }
        // Always offer at least a "Default" entry so the picker isn't empty on first launch.
        return cached.isEmpty ? [HermexProfileEntity(id: "default", name: "Default")] : cached
    }
}

// MARK: - Widget configuration intent

struct HermexNewChatIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "New Chat in Profile"
    static var description = IntentDescription(
        "Start a new Hermex chat in the selected profile."
    )

    @Parameter(title: "Profile")
    var profile: HermexProfileEntity?
}

// MARK: - Deep link helpers (mirrors HermesDeepLink, reads same Info.plist keys)

private var hermexURLScheme: String {
    Bundle.main.object(forInfoDictionaryKey: "HermesURLScheme") as? String ?? "hermes-agent"
}

private var newChatFallbackURL: URL {
    URL(string: "\(hermexURLScheme)://new-chat") ?? URL(string: "hermes-agent://new-chat")!
}

private func newChatInProfileURL(profileID: String) -> URL {
    var c = URLComponents()
    c.scheme = hermexURLScheme
    c.host = "new-chat-profile"
    c.queryItems = [URLQueryItem(name: "profile", value: profileID)]
    return c.url ?? newChatFallbackURL
}

// MARK: - Timeline entry + provider

struct HermexWidgetEntry: TimelineEntry {
    let date: Date
    let profileID: String
    let profileName: String
}

struct HermexWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HermexWidgetEntry {
        HermexWidgetEntry(date: Date(), profileID: "default", profileName: "Default")
    }

    func snapshot(
        for configuration: HermexNewChatIntent,
        in context: Context
    ) async -> HermexWidgetEntry {
        HermexWidgetEntry(
            date: Date(),
            profileID: configuration.profile?.id ?? "default",
            profileName: configuration.profile?.name ?? "Default"
        )
    }

    func timeline(
        for configuration: HermexNewChatIntent,
        in context: Context
    ) async -> Timeline<HermexWidgetEntry> {
        let entry = HermexWidgetEntry(
            date: Date(),
            profileID: configuration.profile?.id ?? "default",
            profileName: configuration.profile?.name ?? "Default"
        )
        return Timeline(entries: [entry], policy: .never)
    }
}

// MARK: - Shared gold gradient

private let hermexGoldGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.80, blue: 0.15),
        Color(red: 0.95, green: 0.48, blue: 0.05)
    ],
    startPoint: .top,
    endPoint: .bottom
)

// MARK: - Shared background (semi-transparent dark + specular highlight)

private struct HermexWidgetBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.88)
            RadialGradient(
                colors: [Color.white.opacity(0.11), Color.clear],
                center: UnitPoint(x: 0.18, y: 0.12),
                startRadius: 0,
                endRadius: 90
            )
        }
    }
}

// MARK: - Small widget (home screen)

private struct HermexSmallWidgetView: View {
    let entry: HermexWidgetEntry

    var body: some View {
        ZStack {
            Image("hermes-fill-mask")
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
                .foregroundStyle(hermexGoldGradient)
                .shadow(color: Color(red: 0.95, green: 0.55, blue: 0.05).opacity(0.4), radius: 12, x: 0, y: 4)
                .offset(y: -8)

            VStack {
                Spacer()
                Text(entry.profileName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { HermexWidgetBackground() }
        .widgetURL(newChatInProfileURL(profileID: entry.profileID))
    }
}

// MARK: - Medium widget (home screen)

private struct HermexMediumWidgetView: View {
    let entry: HermexWidgetEntry

    var body: some View {
        HStack(spacing: 18) {
            Image("hermes-fill-mask")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(hermexGoldGradient)
                .shadow(color: Color(red: 0.95, green: 0.55, blue: 0.05).opacity(0.4), radius: 10, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text("New Chat")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(entry.profileName)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { HermexWidgetBackground() }
        .widgetURL(newChatInProfileURL(profileID: entry.profileID))
    }
}

// MARK: - Lock screen: circular

private struct HermexAccessoryCircularView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("hermes-fill-mask")
                .resizable()
                .scaledToFit()
                .padding(7)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Lock screen: rectangular

private struct HermexAccessoryRectangularView: View {
    let entry: HermexWidgetEntry

    var body: some View {
        HStack(spacing: 8) {
            Image("hermes-fill-mask")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Chat")
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Entry view (dispatches by family)

private struct HermexWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: HermexWidgetEntry

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            HermexSmallWidgetView(entry: entry)
        case .systemMedium:
            HermexMediumWidgetView(entry: entry)
        case .accessoryCircular:
            HermexAccessoryCircularView()
        case .accessoryRectangular:
            HermexAccessoryRectangularView(entry: entry)
        default:
            HermexSmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget declaration

struct HermexHomeWidget: Widget {
    let kind = "HermexHomeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: HermexNewChatIntent.self,
            provider: HermexWidgetProvider()
        ) { entry in
            HermexWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermex")
        .description("Start a new chat in your chosen profile.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}
