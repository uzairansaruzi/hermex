import AppIntents
import Foundation
import WidgetKit

struct BotWidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotWidgetEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

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

    var destinations: [BotWidgetDestination] {
        ([bot].compactMap { $0 } + (bots ?? [])).compactMap(\.destination)
    }
}
