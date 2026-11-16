import AppIntents
import Foundation
import WidgetKit

/// One bot a Bot widget can be configured with (#1643). The id is `<serverKey>|<profile>`, so equal
/// Profile names on two servers are two choices. Shared by the app and the widget.
struct BotWidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotWidgetEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    /// The server digest and Profile the id names, or nil for an id this build can't read.
    var destination: BotWidgetDestination? {
        guard let split = id.firstIndex(of: "|") else { return nil }
        let key = String(id[..<split]), profile = String(id[id.index(after: split)...])
        guard !key.isEmpty, !profile.isEmpty else { return nil }
        return BotWidgetDestination(serverKey: key, profile: profile)
    }

    init(serverKey: String, bot: BotWidgetSnapshot.Bot) {
        id = "\(serverKey)|\(bot.profile)"
        title = bot.title
    }
}

/// The bot picker. It reads only the app's snapshot (`BotWidgetSnapshotFile`): no network, no
/// Keychain, so it answers the same in the app and the widget extension, whichever the system runs
/// it in. Bots are grouped by server once more than one server has bots.
struct BotWidgetEntityQuery: EntityQuery {
    private func snapshot() -> BotWidgetSnapshot { BotWidgetSnapshotFile.shared?.read() ?? BotWidgetSnapshot() }

    func entities(for identifiers: [String]) async throws -> [BotWidgetEntity] {
        let all = snapshot().servers.flatMap { server in server.bots.map { BotWidgetEntity(serverKey: server.serverKey, bot: $0) } }
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> IntentItemCollection<BotWidgetEntity> {
        let servers = snapshot().servers.filter { !$0.bots.isEmpty }
        let sections = servers.map { server in
            let items = server.bots.map { IntentItem(BotWidgetEntity(serverKey: server.serverKey, bot: $0)) }
            return servers.count > 1 ? IntentItemSection("\(server.title)", items: items) : IntentItemSection(items: items)
        }
        return IntentItemCollection(sections: sections)
    }
}

/// A Bot widget's configuration: the one bot a small widget opens, or the bots a medium (up to 4) or
/// large (up to 8) widget shows in order, each opening its own chat. The picker shows only the
/// setting the widget's size uses. Kept out of Shortcuts.
struct BotWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Bot"
    static let description = IntentDescription("Opens this bot's chat in Hermex.")
    static let isDiscoverable = false

    @Parameter(title: "Bot")
    var bot: BotWidgetEntity?

    @Parameter(title: "Bots", size: [.systemMedium: 4, .systemLarge: 8])
    var bots: [BotWidgetEntity]?

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemSmall) {
            Summary { \.$bot }
        } otherwise: {
            Summary { \.$bots }
        }
    }

    init() {}

    init(bot: BotWidgetEntity?, bots: [BotWidgetEntity]? = nil) {
        self.bot = bot
        self.bots = bots
    }

    /// Every bot this widget names, for rendering only the avatars some widget shows.
    var destinations: [BotWidgetDestination] {
        ([bot].compactMap { $0 } + (bots ?? [])).compactMap(\.destination)
    }
}
