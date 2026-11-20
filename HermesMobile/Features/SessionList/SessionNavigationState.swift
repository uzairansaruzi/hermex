import Foundation

enum SessionNavigationDestination: Hashable, Identifiable {
    case session(SessionSummary)
    case newChat(PendingNewChatRoute)
    case utility(SessionListUtilityDestination)

    var id: Self { self }

    var selectedSessionID: String? {
        guard case .session(let session) = self else { return nil }
        return session.sessionId
    }
}

struct SessionNavigationState: Equatable {
    private(set) var destination: SessionNavigationDestination? {
        didSet { chatContinuity = ChatContinuity() }
    }
    private(set) var chatContinuity = ChatContinuity()
    private(set) var lastSelectedSessionID: String?
    private(set) var rootRevision = 0
    private var newChatSessionID: String?
    private var deepLinkedSessionLoadID: String?

    init(lastSelectedSessionID: String? = nil) {
        self.lastSelectedSessionID = Self.normalized(lastSelectedSessionID)
    }

    var selectedSessionID: String? {
        destination?.selectedSessionID ?? newChatSessionID
    }

    var isCreatingNewChat: Bool {
        guard case .newChat = destination else { return false }
        return newChatSessionID == nil
    }

    mutating func select(_ session: SessionSummary) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .session(session)
        remember(session)
    }

    mutating func select(_ route: PendingNewChatRoute) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .newChat(route)
    }

    mutating func select(_ utility: SessionListUtilityDestination) {
        rootRevision += 1
        newChatSessionID = nil
        destination = .utility(utility)
    }

    mutating func remember(_ session: SessionSummary) {
        guard let sessionID = Self.normalized(session.sessionId) else { return }
        lastSelectedSessionID = sessionID
        if case .newChat = destination {
            newChatSessionID = sessionID
        }
    }

    mutating func openSessionList() {
        rootRevision += 1
        clearDestination()
        lastSelectedSessionID = nil
    }

    mutating func clearDestination() {
        destination = nil
        newChatSessionID = nil
    }

    mutating func beginDeepLinkedSessionLoad(id: String?) -> String? {
        guard deepLinkedSessionLoadID == nil,
              let sessionID = Self.normalized(id)
        else { return nil }

        deepLinkedSessionLoadID = sessionID
        return sessionID
    }

    mutating func finishDeepLinkedSessionLoad(id: String?) {
        guard Self.normalized(id) == deepLinkedSessionLoadID else { return }
        deepLinkedSessionLoadID = nil
    }

    mutating func restoreIfNeeded(
        from sessions: [SessionSummary],
        clearsMissingSelection: Bool = true,
        pendingDeepLinkedSessionID: String? = nil
    ) {
        guard destination == nil,
              deepLinkedSessionLoadID == nil,
              Self.normalized(pendingDeepLinkedSessionID) == nil,
              let lastSelectedSessionID
        else { return }

        guard let session = sessions.first(where: {
            Self.normalized($0.sessionId) == lastSelectedSessionID
        }) else {
            if clearsMissingSelection {
                self.lastSelectedSessionID = nil
            }
            return
        }

        destination = .session(session)
    }

    mutating func remove(sessionID: String?) {
        guard let sessionID = Self.normalized(sessionID) else { return }

        if selectedSessionID == sessionID {
            destination = nil
            newChatSessionID = nil
        }

        if lastSelectedSessionID == sessionID {
            lastSelectedSessionID = nil
        }
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ChatShortcutNavigation {
    static func chat<Row>(atPosition position: Int, in chats: [Row]) -> Row? {
        chats.indices.contains(position - 1) ? chats[position - 1] : nil
    }

    static func adjacentChat<Row: Identifiable>(
        offset: Int,
        from selectedID: Row.ID?,
        in chats: [Row]
    ) -> Row? {
        guard !chats.isEmpty else { return nil }
        guard let selectedID,
              let selectedIndex = chats.firstIndex(where: { $0.id == selectedID })
        else {
            return offset > 0 ? chats.first : chats.last
        }

        let count = chats.count
        return chats[((selectedIndex + offset) % count + count) % count]
    }
}

enum SessionNavigationPersistence {
    private static let keyPrefix = "sessionNavigation.lastSelectedSessionID."

    static func key(for server: URL) -> String {
        keyPrefix + server.absoluteString
    }

    static func load(for server: URL, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(for: server))
    }

    static func save(_ sessionID: String?, for server: URL, defaults: UserDefaults = .standard) {
        let key = key(for: server)
        if let sessionID {
            defaults.set(sessionID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

struct SessionUnreadStore {
    var defaults: UserDefaults = .standard

    private func key(for server: URL) -> String {
        "session-inbox-seen." + server.absoluteString
    }

    func load(for server: URL) -> [String: Double] {
        defaults.dictionary(forKey: key(for: server)) as? [String: Double] ?? [:]
    }

    func save(_ seen: [String: Double], for server: URL) {
        defaults.set(seen, forKey: key(for: server))
    }

    func remove(for server: URL) {
        defaults.removeObject(forKey: key(for: server))
    }
}
