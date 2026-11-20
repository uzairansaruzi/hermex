import AppIntents
import Foundation

@MainActor
@Observable
final class AppIntentRouter {
    static let shared = AppIntentRouter()

    var pendingDeepLink: URL?

    private init() {}

    func requestDeepLink(_ url: URL?) {
        guard let url else { return }
        pendingDeepLink = url
    }

    func openNewChat(prefilling text: String, server: URL, profile: String?, origin: ImportedTextOrigin = .shortcut,
                     inbox: URL? = HermesShareDraft.containerURL(), now: Date = Date()) throws {
        guard let inbox else { throw NewChatWithContentError.storage }
        do {
            try HermesShareDraft.saveShortcutText(
                text, for: SharedShortcutDestination(server: server, profile: profile, origin: origin), in: inbox, now: now
            )
        } catch let error as SharedShortcutTextError {
            switch error {
            case .empty: throw NewChatWithContentError.empty
            case .tooLong: throw NewChatWithContentError.tooLong
            case .tooManyWaiting: throw NewChatWithContentError.tooManyWaiting
            }
        } catch {
            throw NewChatWithContentError.storage
        }
        requestDeepLink(HermesShareDraft.openURL)
    }
}

struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open Hermex on a new, empty chat.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UsageReports.shared.record(.appIntents)
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.newChatURL)
        return .result()
    }
}

struct NewChatVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat with Voice"
    static var description = IntentDescription("Open Hermex on a new chat and start voice dictation.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UsageReports.shared.record(.appIntents)
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.newChatVoiceURL)
        return .result()
    }
}

struct NewChatInProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat in Profile"
    static var description = IntentDescription("Open Hermex on a new chat pinned to a specific profile.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("New chat in \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        UsageReports.shared.record(.appIntents)
        let hermes = profile.hermesNewChat
        AppIntentRouter.shared.requestDeepLink(
            HermesDeepLink.newChatInProfileURL(profileName: hermes?.profile ?? profile.id, server: hermes?.server)
        )
        return .result()
    }
}

struct NewChatWithContentIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat with Content"
    static var description = IntentDescription("Open Hermex on a new chat with this text in the composer. Nothing is sent until you send it.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Content", inputOptions: String.IntentInputOptions(multiline: true))
    var content: String

    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$content)") {
            \.$profile
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        UsageReports.shared.record(.appIntents)
        let destination = try Self.destination(profile: profile, active: ProfileEntityProvider.savedServerURL(),
                                               servers: ServerRegistry.shared.servers)
        try AppIntentRouter.shared.openNewChat(prefilling: content, server: destination.server, profile: destination.profile)
        return .result()
    }

    static func destination(profile: ProfileEntity?, active: URL?,
                            servers: [ServerAccount]) throws -> (server: URL, profile: String?) {
        if let profile {
            guard let hermes = profile.hermesNewChat else { throw NewChatWithContentError.noHermesServer }
            return (hermes.server, hermes.profile)
        }
        guard let active, servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else {
            throw NewChatWithContentError.noHermesServer
        }
        return (active, nil)
    }
}

enum NewChatWithContentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case empty
    case tooLong
    case tooManyWaiting
    case noHermesServer
    case storage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: "There’s no text to add to a new chat."
        case .tooLong: "That text is too long. A Shortcut can add up to 100 KB."
        case .tooManyWaiting: "10 Shortcut texts are already waiting. Open Hermex to review them first."
        case .noHermesServer: "Choose a Profile on a Hermes server, or make a Hermes server active in Hermex."
        case .storage: "Hermex couldn’t save the text. Try again."
        }
    }
}

struct HermexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "New \(.applicationName) chat",
                "Start a new chat in \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: NewChatVoiceIntent(),
            phrases: [
                "New voice chat in \(.applicationName)",
                "New \(.applicationName) voice chat",
                "Start a voice chat in \(.applicationName)"
            ],
            shortTitle: "New Chat with Voice",
            systemImageName: "mic.badge.plus"
        )
        AppShortcut(
            intent: NewChatInProfileIntent(),
            phrases: [
                "New \(\.$profile) chat in \(.applicationName)",
                "Start a new \(\.$profile) chat in \(.applicationName)",
                "New chat in \(\.$profile) on \(.applicationName)"
            ],
            shortTitle: "New Chat in Profile",
            systemImageName: "person.crop.circle.badge.plus"
        )
        AppShortcut(
            intent: NewChatWithContentIntent(),
            phrases: [
                "New chat with content in \(.applicationName)",
                "Start a \(.applicationName) chat with content"
            ],
            shortTitle: "New Chat with Content",
            systemImageName: "text.bubble"
        )
    }
}

extension SharedShortcutDestination {
    func newChat(in servers: [ServerAccount]) -> HermesNewChatDestination? {
        servers.lazy.filter { $0.kind == .hermes }.compactMap { URL(string: $0.id) }.first(where: opens(on:))
            .map { HermesNewChatDestination(server: $0, profile: profile) }
    }
}

struct HermesNewChatDestination: Hashable {
    let server: URL
    let profile: String?
    var autoStartsVoiceInput = false
    let id = UUID()

    enum Route: Equatable {
        case ignore
        case waitForSignIn
        case switchServer(ServerAccount)
        case open
    }

    init(server: URL, profile: String?, autoStartsVoiceInput: Bool = false) {
        self.server = server
        self.profile = profile
        self.autoStartsVoiceInput = autoStartsVoiceInput
    }

    init?(url: URL) {
        guard HermesDeepLink.isNewChatInProfileURL(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == HermesDeepLink.serverQueryItem })?.value,
              let server = Self.server(raw),
              let profile = HermesDeepLink.profileName(fromNewChatInProfile: url) else { return nil }
        self.init(server: server, profile: profile)
    }

    static func server(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    @MainActor static func onActiveServer(state: AuthManager.State, servers: [ServerAccount],
                                          autoStartsVoiceInput: Bool) -> Self? {
        guard let active = state.server,
              servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else { return nil }
        return Self(server: active, profile: nil, autoStartsVoiceInput: autoStartsVoiceInput)
    }

    @MainActor func route(state: AuthManager.State, servers: [ServerAccount]) -> Route {
        guard let account = servers.first(where: { $0.id == server.absoluteString }), account.kind == .hermes else {
            return .ignore
        }
        guard state.server == server else { return .switchServer(account) }
        if case .loggedIn = state { return .open }
        return .waitForSignIn
    }

    @MainActor func chat(on entry: HermesSessionListEntry, listed: String?, isLive: Bool) -> HermesSessionChat? {
        guard entry.server == server, isLive, let profile = profile ?? listed else { return nil }
        return HermesSessionChat(server: server, connection: entry.connection, target: .new(profile: profile),
                                 autoStartsVoiceInput: autoStartsVoiceInput)
    }
}
