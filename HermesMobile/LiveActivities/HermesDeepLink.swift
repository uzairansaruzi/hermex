import Foundation

enum HermesDeepLink {
    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesURLScheme") as? String
            ?? "hermes-agent"
    }

    static let sessionHost = "session"

    static let subagentQueryItem = "subagent"

    static let botHost = "bot"

    static let usageHost = "usage"

    static let newChatHost = "new-chat"

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

    static let newChatVoiceHost = "new-chat-voice"

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

    static let newChatInProfileHost = "new-chat-profile"

    static let profileQueryItem = "profile"

    static let serverQueryItem = "server"

    static func newChatInProfileURL(profileName: String, server: URL? = nil) -> URL? {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = newChatInProfileHost
        components.queryItems = (server.map { [URLQueryItem(name: serverQueryItem, value: $0.absoluteString)] } ?? [])
            + [URLQueryItem(name: profileQueryItem, value: trimmed)]
        return components.url
    }

    static func isNewChatInProfileURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == newChatInProfileHost
    }

    static func isWebuiNewChatInProfileURL(_ url: URL) -> Bool {
        isNewChatInProfileURL(url)
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == serverQueryItem }) != true
    }

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

    static func sessionURL(for destination: HermesSessionDestination) -> URL? {
        guard let key = normalizedSessionID(destination.key) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionHost
        var items = [URLQueryItem(name: "server", value: destination.server.absoluteString)]
        if let profile = destination.profile {
            items.append(URLQueryItem(name: profileQueryItem, value: profile.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        items.append(URLQueryItem(name: "id", value: key))
        if destination.opensParent { items.append(URLQueryItem(name: subagentQueryItem, value: "1")) }
        components.queryItems = items
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
        guard components?.queryItems?.contains(where: { $0.name == "server" }) != true else { return nil }
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

    static func normalizedSessionID(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct HermesSessionDestination: Hashable {
    let server: URL
    let profile: String?
    let key: String
    var opensParent = false
    var movedFrom: URL?
}

enum AgentRunTapTarget {
    static let hermesSessionPrefix = "hermes:"

    static func url(attributes: AgentRunActivityAttributes, sessionID: String, activityID: String) -> URL? {
        let destination: URL?
        if let bot = attributes.bot {
            destination = bot.destinationURL
        } else if let link = attributes.destinationURL {
            destination = link
        } else if attributes.sessionID.hasPrefix(hermesSessionPrefix) {
            return nil
        } else if let server = attributes.server {
            destination = HermesDeepLink.webuiSessionURL(server: server, sessionID: sessionID)
        } else {
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
