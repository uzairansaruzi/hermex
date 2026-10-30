import Foundation

/// One row of the quick switcher (#1415): identity only, resolved by the Hermes
/// home when picked, so a stale pick can never open under the wrong server.
enum QuickSwitcherItem: Hashable, Identifiable {
    /// A loaded session row: its stored key and Profile, as a session link (#1176)
    /// names them. The home routes it through `pendingSessionDestination`, so it
    /// inherits the live lookup, its offline behavior included.
    case session(key: String, profile: String?, title: String)
    /// A bot on the roster: `BotProfile.id`, the Profile name the bot route keys by.
    case bot(profile: String, title: String)
    /// A home destination: Tasks, Kanban, Skills, Memory, Usage, Archived or Settings.
    case utility(SessionListUtilityDestination)

    var id: Self { self }

    var title: String {
        switch self {
        case .session(_, _, let title), .bot(_, let title):
            return title
        case .utility(let destination):
            return Self.utilityTitle(destination)
        }
    }

    /// The row names destinations as the home's sidebar does, so a query matches
    /// what the user reads there.
    static func utilityTitle(_ destination: SessionListUtilityDestination) -> String {
        switch destination {
        case .settings:
            return String(localized: "Settings")
        case .notificationSettings:
            return String(localized: "Notifications")
        case .bots:
            return String(localized: "Bots")
        case .tasks:
            return String(localized: "Tasks")
        case .kanban:
            return String(localized: "Kanban")
        case .skills:
            return String(localized: "Skills")
        case .memory:
            return String(localized: "Memory")
        case .insights:
            return String(localized: "Usage")
        case .archived:
            return String(localized: "Archived Sessions")
        case .scheduled:
            return String(localized: "Scheduled Sessions")
        }
    }
}

/// What the switcher searches: a snapshot of the active server's loaded rows and
/// roster, taken when the sheet opens, so a live update cannot reshuffle a query
/// mid-typing. Only the active server's items ever enter it; a server switch
/// rebuilds the home, which dismisses the sheet with it.
struct QuickSwitcherSnapshot {
    let server: URL
    /// The active server's saved Bot connection, for bot routes. Sessions open
    /// without one; bots cannot be routed without it.
    let connectionID: UUID?
    let sessions: [SessionSummary]
    let bots: [BotProfile]
    let destinations: [SessionListUtilityDestination]
    /// The open chat's session key, so its row lists last in the recents.
    let openSessionKey: String?
}

/// What picking an item should do, decided purely so the home's routing and the
/// tests agree on identity without a view.
enum QuickSwitcherPick: Equatable {
    case session(HermesSessionDestination)
    case bot(BotDestination)
    case settings
    /// A utility pick lands on the Sessions side, whose list owns the screens.
    case sessionsUtility(SessionListUtilityDestination)
}

enum QuickSwitcherModel {
    /// The rows the palette shows for `query`. An empty query lists recents —
    /// newest first, the open chat last — then the roster, then the destinations.
    /// A query filters all three with the session list's multi-word rule.
    static func items(sessions: [SessionSummary], bots: [BotProfile],
                      destinations: [SessionListUtilityDestination],
                      query: String, openSessionKey: String?) -> [QuickSwitcherItem] {
        // Recents are newest first, whatever order the caller's rows hold, and the
        // open chat lists last so it never sits between the user and their next pick.
        let recents = sessions.sorted { left, right in
            SessionListViewModel.timestamp(for: left) > SessionListViewModel.timestamp(for: right)
        }
        let ordered = recents.filter { $0.hermesSessionKey != openSessionKey }
            + recents.filter { $0.hermesSessionKey == openSessionKey }

        let terms = SessionListViewModel.normalizedSearchQuery(query).split(whereSeparator: \.isWhitespace)
        if terms.isEmpty {
            return ordered.map(\.item) + bots.map(\.item) + destinations.map(\.item)
        }

        let sessionItems = ordered.filter { session in
            SessionListViewModel.matches(searchTerms: terms, in: SessionListViewModel.searchableText(for: session))
        }.map(\.item)
        let botItems = bots.filter { bot in
            SessionListViewModel.matches(searchTerms: terms, in: botSearchableText(for: bot))
        }.map(\.item)
        let destinationItems = destinations.filter { destination in
            SessionListViewModel.matches(searchTerms: terms, in: QuickSwitcherItem.utilityTitle(destination).lowercased())
        }
        return sessionItems + botItems + destinationItems
    }

    /// The roster's searchable fields, the way the inbox's tile search reads a
    /// bot: its name, Desktop title, display name and section.
    private static func botSearchableText(for bot: BotProfile) -> String {
        [bot.name, bot.title, bot.displayName, bot.sectionName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    /// The home destinations the switcher offers, in the sidebar's order: the rows
    /// the user hid stay hidden, and Archived follows the list's own availability.
    /// Settings is always last and always there.
    static func destinations(showsTasks: Bool, showsKanban: Bool, showsSkills: Bool,
                             showsMemory: Bool, showsInsights: Bool, showsArchived: Bool) -> [SessionListUtilityDestination] {
        var destinations: [SessionListUtilityDestination] = []
        if showsTasks { destinations.append(.tasks) }
        if showsKanban { destinations.append(.kanban) }
        if showsSkills { destinations.append(.skills) }
        if showsMemory { destinations.append(.memory) }
        if showsInsights { destinations.append(.insights) }
        if showsArchived { destinations.append(.archived) }
        destinations.append(.settings)
        return destinations
    }

    /// What a pick should do on `server`, or nil when its identity is incomplete —
    /// a row or bot the snapshot caught without the key its route needs.
    static func pick(_ item: QuickSwitcherItem, on server: URL, connectionID: UUID?) -> QuickSwitcherPick? {
        switch item {
        case .session(let key, let profile, _):
            guard !key.isEmpty else { return nil }
            return .session(HermesSessionDestination(server: server, profile: profile, key: key))
        case .bot(let profile, _):
            guard let connectionID else { return nil }
            return .bot(BotDestination(server: server, connectionID: connectionID, profile: profile, conversation: nil))
        case .utility(.settings):
            return .settings
        case .utility(let destination):
            return .sessionsUtility(destination)
        }
    }

    /// Whether the home may still route a pick taken before its sheet closed: the
    /// app lock must be down and the active server must still be the one the
    /// snapshot names, so a switch while dismissal was pending opens nothing.
    static func canRoute(pickServerID: String, activeServerID: String?, isLocked: Bool) -> Bool {
        !isLocked && activeServerID == pickServerID
    }
}

private extension SessionSummary {
    /// The key a session route names. A row the host has not keyed yet has none.
    var hermesSessionKey: String? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        return sessionId
    }

    var item: QuickSwitcherItem {
        .session(key: hermesSessionKey ?? "", profile: profile, title: SessionRowView.displayTitle(for: self))
    }
}

private extension BotProfile {
    var item: QuickSwitcherItem {
        .bot(profile: id, title: displayName ?? name)
    }
}
