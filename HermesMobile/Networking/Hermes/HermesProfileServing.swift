import Foundation

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

    /// One duplicate-credential blocker, as upstream's `duplicate_credential_lines` words it at
    /// the pin: the Profile that claims the bot first, the other, and the platform.
    private static let duplicate = #/Profiles '(?<keep>[^']+)' and '(?<other>[^']+)' both hold the same (?<platform>[\w-]+) credential \([^)]*\):.*?hermes gateway migrate --multiplex\./#
        .dotMatchesNewlines()

    /// "dev and default use the same Telegram and Discord bots." when every blocker is a
    /// duplicate bot shared by one pair of Profiles; nil for anything else.
    private static func summary(of text: String) -> String? {
        let matches = text.matches(of: duplicate)
        guard let first = matches.first else { return nil }
        let leftover = matches.reversed().reduce(into: text) { $0.removeSubrange($1.range) }
        guard leftover.allSatisfy({ $0 == ";" || $0.isWhitespace }) else { return nil }
        let pair = (keep: String(first.keep), other: String(first.other))
        guard matches.allSatisfy({ $0.keep == pair.keep && $0.other == pair.other }) else { return nil }
        var platforms: [String] = []
        for match in matches {
            let name = platformName(String(match.platform))
            if !platforms.contains(name) { platforms.append(name) }
        }
        if platforms.count == 1 {
            return String(localized: "\(pair.other) and \(pair.keep) use the same \(platforms[0]) bot.")
        }
        let list = platforms.formatted(.list(type: .and))
        return String(localized: "\(pair.other) and \(pair.keep) use the same \(list) bots.")
    }

    /// A platform id as people write it: `telegram` reads Telegram.
    private static func platformName(_ id: String) -> String {
        let known = ["whatsapp": "WhatsApp", "imessage": "iMessage", "wecom": "WeCom", "qq": "QQ", "sms": "SMS"]
        return known[id] ?? id.capitalized
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
