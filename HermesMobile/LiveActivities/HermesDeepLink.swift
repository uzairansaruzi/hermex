import Foundation

enum HermesDeepLink {
    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesURLScheme") as? String
            ?? "hermes-agent"
    }

    static let sessionHost = "session"

    /// Host for the one bot route (#554): `hermes-agent://bot?server=…&connection=…&profile=…`.
    /// The builder, parser and typed `BotDestination` live in `Features/Bots/BotDeepLink.swift`,
    /// which is main-app only; this file is shared with the Live Activity widget.
    static let botHost = "bot"

    /// Host for the parameter-less "open the New Chat composer" deep link used by the
    /// New Chat App Intent (issue #337). Mirrors the share extension's host-based routing
    /// so the intent can reuse `ContentView.handleOpenURL` rather than inventing a new path.
    static let newChatHost = "new-chat"

    /// `hermes-agent://new-chat` (scheme follows the active build, e.g. `-branch`).
    static var newChatURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = newChatHost
        return components.url
    }

    static func isNewChatURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == newChatHost
    }

    /// Host for "open the New Chat composer *and* auto-start voice dictation", used by the
    /// "New Chat with Voice" App Intent (issue #338). A distinct host from `newChatHost`
    /// so the two intents never alias each other — `isNewChatURL` and `isNewChatVoiceURL`
    /// are mutually exclusive.
    static let newChatVoiceHost = "new-chat-voice"

    /// `hermes-agent://new-chat-voice` (scheme follows the active build, e.g. `-branch`).
    static var newChatVoiceURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = newChatVoiceHost
        return components.url
    }

    static func isNewChatVoiceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == newChatVoiceHost
    }

    /// Host for "open the New Chat composer pinned to a specific profile", used by the
    /// "New Chat in <Profile>" App Intent (issue #339). A distinct host from the other
    /// new-chat hosts so the three intents never alias; the profile name rides as a query
    /// item (like `sessionURL`'s `id`) rather than in the host, so it can carry spaces and
    /// non-ASCII safely via percent-encoding.
    static let newChatInProfileHost = "new-chat-profile"

    /// Query-item name carrying the profile's server name.
    static let profileQueryItem = "profile"

    /// `hermes-agent://new-chat-profile?profile=<name>` (scheme follows the active build).
    /// Returns nil for a blank profile name so callers can pass it straight through.
    static func newChatInProfileURL(profileName: String) -> URL? {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = newChatInProfileHost
        components.queryItems = [URLQueryItem(name: profileQueryItem, value: trimmed)]
        return components.url
    }

    static func isNewChatInProfileURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == newChatInProfileHost
    }

    /// Extracts the profile name from a "New Chat in <Profile>" URL, or nil when the URL is a
    /// different kind or carries no (non-blank) profile.
    static func profileName(fromNewChatInProfile url: URL) -> String? {
        guard isNewChatInProfileURL(url) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let raw = components?.queryItems?.first(where: { $0.name == profileQueryItem })?.value
        else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Server-owned webui destination, shared by notification and Live Activity taps.
    /// The main app's WebuiPushDestination parses it and owns sign-in/server routing.
    static func webuiSessionURL(server: URL, sessionID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "webui-push"
        components.queryItems = [
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "id", value: sessionID)
        ]
        return components.url
    }

    static func sessionURL(sessionID: String) -> URL? {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionHost
        components.queryItems = [
            URLQueryItem(name: "id", value: sessionID)
        ]
        return components.url
    }

    static func sessionID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == sessionHost
        else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let id = components?.queryItems?.first(where: { item in
            item.name == "id" || item.name == "session_id"
        })?.value {
            return normalizedSessionID(id)
        }

        let pathID = url.pathComponents
            .filter { $0 != "/" }
            .first
        return normalizedSessionID(pathID)
    }

    private static func normalizedSessionID(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Shared by the Lock Screen and Dynamic Island, and exercised by main-app tests.
enum AgentRunTapTarget {
    /// Starts a Hermes session's interim activity key, `hermes:<profile>:<stored key>`
    /// (#1014). Until #706 such an activity has no destination: a tap opens the app as it is.
    static let hermesSessionPrefix = "hermes:"

    static func url(attributes: AgentRunActivityAttributes, sessionID: String, activityID: String) -> URL? {
        guard attributes.bot != nil || !attributes.sessionID.hasPrefix(hermesSessionPrefix) else { return nil }
        let destination: URL?
        if let bot = attributes.bot {
            destination = bot.destinationURL
        } else if let server = attributes.server {
            destination = HermesDeepLink.webuiSessionURL(server: server, sessionID: sessionID)
        } else {
            // Activities persisted before server ownership was recorded keep their old route.
            destination = HermesDeepLink.sessionURL(sessionID: sessionID)
        }
        guard let destination,
              var components = URLComponents(url: destination, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "activity" }
        items.append(URLQueryItem(name: "activity", value: activityID))
        components.queryItems = items
        return components.url
    }

    static func activityID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme,
              [HermesDeepLink.sessionHost, HermesDeepLink.botHost, "webui-push"].contains(url.host?.lowercased() ?? "")
        else { return nil }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "activity" })?.value
        return id?.isEmpty == false ? id : nil
    }
}
