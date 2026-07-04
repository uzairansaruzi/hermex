import Foundation

struct HermesNewChatDeepLinkPayload: Equatable {
    let initialPrompt: String?
    let model: String?
    let modelProvider: String?
    let profileName: String?
    let autoStartsVoiceInput: Bool
}

enum HermesDeepLink {
    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesURLScheme") as? String
            ?? "hermes-agent"
    }

    static let sessionHost = "session"

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

    /// Query-item name carrying an initial composer draft for Wiki/App launch buttons.
    static let promptQueryItem = "prompt"

    /// Alternate initial-draft query item accepted for web callers that naturally say
    /// "message". `prompt` is preferred for generated links so the URL contract is stable.
    static let messageQueryItem = "message"

    /// Query-item name carrying the model id to pin the newly created session to.
    static let modelQueryItem = "model"

    /// Query-item name carrying the provider id for ambiguous model ids.
    static let modelProviderQueryItem = "provider"

    /// Alternate provider query name matching the server's snake_case API body.
    static let modelProviderSnakeQueryItem = "model_provider"

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

    /// Builds a New Chat deep link that can prefill the composer and optionally preselect
    /// model/provider/profile. This is the URL shape Wiki Apps can use for buttons:
    ///
    /// `hermes-agent://new-chat?prompt=...&model=...&provider=...&profile=...`
    ///
    /// Existing parameter-less and profile-only deep links remain valid.
    static func newChatLaunchURL(
        prompt: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        profileName: String? = nil,
        autoStartsVoiceInput: Bool = false
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = autoStartsVoiceInput ? newChatVoiceHost : newChatHost

        var queryItems: [URLQueryItem] = []
        if let prompt = Self.nonEmpty(prompt) {
            queryItems.append(URLQueryItem(name: promptQueryItem, value: prompt))
        }
        if let model = Self.nonEmpty(model) {
            queryItems.append(URLQueryItem(name: modelQueryItem, value: model))
        }
        if let modelProvider = Self.nonEmpty(modelProvider) {
            queryItems.append(URLQueryItem(name: modelProviderQueryItem, value: modelProvider))
        }
        if let profileName = Self.nonEmpty(profileName) {
            queryItems.append(URLQueryItem(name: profileQueryItem, value: profileName))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    static func newChatPayload(from url: URL) -> HermesNewChatDeepLinkPayload? {
        let autoStartsVoiceInput: Bool
        if isNewChatVoiceURL(url) {
            autoStartsVoiceInput = true
        } else if isNewChatURL(url) || isNewChatInProfileURL(url) {
            autoStartsVoiceInput = false
        } else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let profileName = isNewChatInProfileURL(url)
            ? Self.profileName(fromNewChatInProfile: url)
            : Self.queryValue(named: profileQueryItem, in: queryItems)

        return HermesNewChatDeepLinkPayload(
            initialPrompt: Self.queryValue(named: promptQueryItem, in: queryItems)
                ?? Self.queryValue(named: messageQueryItem, in: queryItems),
            model: Self.queryValue(named: modelQueryItem, in: queryItems),
            modelProvider: Self.queryValue(named: modelProviderQueryItem, in: queryItems)
                ?? Self.queryValue(named: modelProviderSnakeQueryItem, in: queryItems),
            profileName: profileName,
            autoStartsVoiceInput: autoStartsVoiceInput
        )
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

    private static func queryValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        guard let rawValue = queryItems.first(where: { $0.name == name })?.value else {
            return nil
        }
        return Self.nonEmpty(rawValue)
    }

    private static func nonEmpty(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
