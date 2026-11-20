import Foundation

struct HermesDuplicateBot: Hashable, Identifiable, Sendable {
    let keeper: String
    let other: String
    let platform: String
    let keys: [String]

    var id: String { "\(keeper)\u{1F}\(other)\u{1F}\(platform)" }

    var platformName: String {
        let known = ["whatsapp": "WhatsApp", "imessage": "iMessage", "wecom": "WeCom", "qq": "QQ", "sms": "SMS"]
        return known[platform] ?? platform.capitalized
    }

    private static let pattern = #/Profiles '(?<keep>[^']+)' and '(?<other>[^']+)' both hold the same (?<platform>[\w-]+) credential \((?<keys>[^)]*)\):.*?hermes gateway migrate --multiplex\./#
        .dotMatchesNewlines()

    static func parse(_ text: String) -> (bots: [HermesDuplicateBot], rest: String) {
        let matches = text.matches(of: pattern)
        let rest = matches.reversed().reduce(into: text) { $0.removeSubrange($1.range) }
        let bots = matches.map { match in
            let names = match.keys.split(separator: "/").map(String.init)
            let removable = !names.isEmpty && names.allSatisfy { $0.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } }
            return HermesDuplicateBot(keeper: String(match.keep), other: String(match.other),
                                      platform: String(match.platform), keys: removable ? names : [])
        }
        return (bots, rest)
    }

    static func isEmpty(_ rest: String) -> Bool { rest.allSatisfy { $0 == ";" || $0.isWhitespace } }
}

struct HermesStandaloneReason: Equatable, Sendable {
    let hostText: String
    let summary: String?

    init(hostText: String) {
        self.hostText = hostText
        summary = Self.summary(of: hostText)
    }

    private static func summary(of text: String) -> String? {
        let (bots, rest) = HermesDuplicateBot.parse(text)
        guard let first = bots.first, HermesDuplicateBot.isEmpty(rest),
              bots.allSatisfy({ $0.keeper == first.keeper && $0.other == first.other }) else { return nil }
        var platforms: [String] = []
        for bot in bots where !platforms.contains(bot.platformName) { platforms.append(bot.platformName) }
        if platforms.count == 1 {
            return String(localized: "\(first.other) and \(first.keeper) use the same \(platforms[0]) bot.")
        }
        let list = platforms.formatted(.list(type: .and))
        return String(localized: "\(first.other) and \(first.keeper) use the same \(list) bots.")
    }
}

struct HermesProfileServing: Equatable, Sendable {
    let reason: HermesStandaloneReason?
    let profileCount: Int

    init(status: BotJSON) {
        reason = status["multiplex_standalone_reason"].text.flatMap { $0.isEmpty ? nil : HermesStandaloneReason(hostText: $0) }
        let parked = Set((status["parked_profiles"].list ?? []).compactMap(\.text))
        profileCount = (status["profiles"].list ?? []).compactMap(\.text).filter { !parked.contains($0) }.count
    }

    @MainActor static func read(on http: HermesConnection) async throws -> HermesProfileServing {
        HermesProfileServing(status: try JSONDecoder().decode(BotJSON.self, from: try await http.data(.status)))
    }
}

struct HermesMigrationPlan: Equatable, Sendable {
    let duplicateBots: [HermesDuplicateBot]
    let otherBlockers: [String]
    let movedListeners: [String]
    let servesEveryProfile: Bool

    private let plan: BotJSON

    var isBlocked: Bool { !duplicateBots.isEmpty || !otherBlockers.isEmpty }

    init(_ plan: BotJSON, unhandled: Set<HermesDuplicateBot.ID> = []) {
        self.plan = plan
        var bots: [HermesDuplicateBot] = [], others: [String] = []
        for blocker in (plan["blockers"].list ?? []).compactMap(\.text) {
            let (found, rest) = HermesDuplicateBot.parse(blocker)
            if let bot = found.first, found.count == 1, !bot.keys.isEmpty, HermesDuplicateBot.isEmpty(rest),
               !unhandled.contains(bot.id) {
                bots.append(bot)
            } else {
                others.append(blocker)
            }
        }
        duplicateBots = bots
        otherBlockers = others
        movedListeners = (plan["notices"].list ?? []).compactMap(\.text).filter { $0.contains("moves onto the default listener") }
        servesEveryProfile = plan["already_multiplexed"].flag == true && (plan["live_served"].list?.count ?? 0) > 1
    }

    func unhandling(_ ids: Set<HermesDuplicateBot.ID>) -> HermesMigrationPlan { HermesMigrationPlan(plan, unhandled: ids) }
}

@MainActor final class HermesGatewayMigrationClient {
    private let http: HermesConnection

    init(http: HermesConnection) { self.http = http }

    func plan() async throws -> HermesMigrationPlan {
        HermesMigrationPlan(try JSONDecoder().decode(BotJSON.self, from: try await http.data(.migrationPlan)))
    }

    func remove(_ bot: HermesDuplicateBot, from profile: String) async throws {
        for key in bot.keys {
            let reply = try await http.reply(.removeEnvironment(key: key, profile: profile))
            if reply.status == 404 { continue }
            _ = try HermesCronClient.accepted(reply)
        }
    }

    func migrate() async throws {
        let reply = try JSONDecoder().decode(BotJSON.self, from: try await http.data(.migrateGateway))
        guard reply["ok"].flag == true else { throw BotFailure.unsupported }
    }

    func opens(profile: String) async -> Bool {
        let probe = BotClient(http: http, profile: profile)
        defer { probe.close() }
        return (try? await probe.connect()) != nil
    }
}
