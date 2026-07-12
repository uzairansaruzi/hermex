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
    private(set) var destination: SessionNavigationDestination?
    private(set) var lastSelectedSessionID: String?
    private(set) var rootRevision = 0
    private var newChatSessionID: String?

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

    mutating func clearDestination() {
        destination = nil
        newChatSessionID = nil
    }

    /// Restores only when no explicit route already won. Deep links, shared drafts,
    /// and App Intent requests therefore take precedence over the stored selection.
    mutating func restoreIfNeeded(
        from sessions: [SessionSummary],
        clearsMissingSelection: Bool = true
    ) {
        guard destination == nil, let lastSelectedSessionID else { return }

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

    /// Invalidates both the visible detail and stored restoration target when the
    /// removed session is the selected or most recently selected session.
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
