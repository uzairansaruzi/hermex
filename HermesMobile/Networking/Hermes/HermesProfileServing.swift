import Foundation

/// A bot credential two Profiles both hold, which keeps a gateway from serving every Profile
/// (#1611). Read from the prose of upstream's `duplicate_credential_lines`, the one blocker
/// Hermex fixes itself: names only, never a value.
struct HermesDuplicateBot: Hashable, Identifiable, Sendable {
    /// The Profile that claims the bot first and answers on it today.
    let keeper: String
    let other: String
    /// The platform id, such as `telegram`.
    let platform: String
    /// The `.env` names that hold the credential; empty when the host names none, as for a
    /// token set only in config.yaml, which Hermex can't remove.
    let keys: [String]

    var id: String { "\(keeper)\u{1F}\(other)\u{1F}\(platform)" }

    /// The platform as people write it: `telegram` reads Telegram.
    var platformName: String {
        let known = ["whatsapp": "WhatsApp", "imessage": "iMessage", "wecom": "WeCom", "qq": "QQ", "sms": "SMS"]
        return known[platform] ?? platform.capitalized
    }

    /// One blocker, worded as upstream words it at the pin.
    private static let pattern = #/Profiles '(?<keep>[^']+)' and '(?<other>[^']+)' both hold the same (?<platform>[\w-]+) credential \((?<keys>[^)]*)\):.*?hermes gateway migrate --multiplex\./#
        .dotMatchesNewlines()

    /// Every duplicate bot in `text`, and whatever else it says once they are taken out.
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

    /// Whether `rest` from `parse` says nothing more: only the separators between blockers.
    static func isEmpty(_ rest: String) -> Bool { rest.allSatisfy { $0 == ";" || $0.isWhitespace } }
}

/// Why a gateway's Webapp serves only one Profile (#1611): the host's own words, from the
/// signed-in `/api/status`'s `multiplex_standalone_reason`, and a plain summary when Hermex
/// recognizes every blocker in them. The host gives blockers as prose only, so an
/// unrecognized one leaves `summary` nil and the host's words stand on their own.
struct HermesStandaloneReason: Equatable, Sendable {
    let hostText: String
    let summary: String?

    init(hostText: String) {
        self.hostText = hostText
        summary = Self.summary(of: hostText)
    }

    /// "dev and default use the same Telegram and Discord bots." when every blocker is a
    /// duplicate bot shared by one pair of Profiles; nil for anything else.
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

/// What the signed-in `/api/status` says about which Profiles a gateway serves (#1611). Only a
/// gateway's Webapp reads it: a dashboard serves every Profile itself.
struct HermesProfileServing: Equatable, Sendable {
    /// Why the gateway serves only one Profile; nil when it serves every one, or when the host
    /// doesn't say.
    let reason: HermesStandaloneReason?
    /// The host's Profiles, parked ones left out: what serving every Profile would serve.
    let profileCount: Int

    init(status: BotJSON) {
        reason = status["multiplex_standalone_reason"].text.flatMap { $0.isEmpty ? nil : HermesStandaloneReason(hostText: $0) }
        let parked = Set((status["parked_profiles"].list ?? []).compactMap(\.text))
        profileCount = (status["profiles"].list ?? []).compactMap(\.text).filter { !parked.contains($0) }.count
    }

    /// Reads the signed-in status over `http`.
    @MainActor static func read(on http: HermesConnection) async throws -> HermesProfileServing {
        HermesProfileServing(status: try JSONDecoder().decode(BotJSON.self, from: try await http.data(.status)))
    }
}

/// `GET /api/gateway/migrate/plan`, the preflight for serving every Profile from one gateway
/// (#1611). Never gate on its `eligible`: that is `hermes update`'s bar for migrating on its own,
/// false on a host where no Profile runs its own gateway even when the migrate command works.
struct HermesMigrationPlan: Equatable, Sendable {
    /// Duplicate bots Hermex can remove a credential for.
    let duplicateBots: [HermesDuplicateBot]
    /// Every other blocker, in the host's words.
    let otherBlockers: [String]
    /// The host's notices about a platform whose address moves under `/p/<profile>/`.
    let movedListeners: [String]
    let alreadyMultiplexed: Bool

    var isBlocked: Bool { !duplicateBots.isEmpty || !otherBlockers.isEmpty }

    init(_ plan: BotJSON) {
        var bots: [HermesDuplicateBot] = [], others: [String] = []
        for blocker in (plan["blockers"].list ?? []).compactMap(\.text) {
            let (found, rest) = HermesDuplicateBot.parse(blocker)
            if let bot = found.first, found.count == 1, !bot.keys.isEmpty, HermesDuplicateBot.isEmpty(rest) {
                bots.append(bot)
            } else {
                others.append(blocker)
            }
        }
        duplicateBots = bots
        otherBlockers = others
        // Upstream's `_check_secondary_port_binders` notice; the others are about `hermes update`.
        movedListeners = (plan["notices"].list ?? []).compactMap(\.text).filter { $0.contains("moves onto the default listener") }
        alreadyMultiplexed = plan["already_multiplexed"].flag == true
    }
}

/// The guided fix that makes one gateway serve every Profile (#1611): read the preflight,
/// remove a duplicate bot credential from the Profile that shouldn't keep it, then start the
/// migration, which restarts the gateway. Over the sign-in the server's Bot screens share.
@MainActor final class HermesGatewayMigrationClient {
    private let http: HermesConnection

    init(http: HermesConnection) { self.http = http }

    func plan() async throws -> HermesMigrationPlan {
        HermesMigrationPlan(try JSONDecoder().decode(BotJSON.self, from: try await http.data(.migrationPlan)))
    }

    /// Removes `bot`'s credential from `profile`'s `.env`. A key the `.env` lacks (404) is left
    /// for the plan read that follows to judge; the host never sends a value back.
    func remove(_ bot: HermesDuplicateBot, from profile: String) async throws {
        for key in bot.keys {
            let reply = try await http.reply(.removeEnvironment(key: key, profile: profile))
            if reply.status == 404 { continue }
            _ = try HermesCronClient.accepted(reply)
        }
    }

    /// Starts the migration. Its answer means only that it started; the gateway then restarts.
    func migrate() async throws {
        let reply = try JSONDecoder().decode(BotJSON.self, from: try await http.data(.migrateGateway))
        guard reply["ok"].flag == true else { throw BotFailure.unsupported }
    }

    /// Whether `profile`'s chats open on this Webapp, joining its socket for a moment.
    func opens(profile: String) async -> Bool {
        let probe = BotClient(http: http, profile: profile)
        defer { probe.close() }
        return (try? await probe.connect()) != nil
    }
}
