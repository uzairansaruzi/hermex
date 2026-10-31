import AppIntents
import Foundation

/// Bridges App Intents (which run outside the SwiftUI view tree) into the app's existing
/// deep-link router. An intent writes a `hermes-agent://…` URL here; `ContentView` observes
/// `pendingDeepLink` and feeds it through the same `handleOpenURL` path as an external URL,
/// so intent navigation reuses the share/session deep-link plumbing rather than inventing a
/// parallel one (issue #337). A shared singleton is the standard bridge because the intent
/// has no reference to the live view hierarchy.
@MainActor
@Observable
final class AppIntentRouter {
    static let shared = AppIntentRouter()

    /// Set by an App Intent, drained by `ContentView`. Holding it (rather than acting
    /// immediately) lets the view consume it whether the intent fired before the view
    /// appeared (cold launch) or after (warm launch).
    var pendingDeepLink: URL?

    private init() {}

    /// Records a deep link for the view layer to route. No-op on a nil URL so callers can
    /// pass the optional `HermesDeepLink` builders without unwrapping.
    func requestDeepLink(_ url: URL?) {
        guard let url else { return }
        pendingDeepLink = url
    }

    /// Opens a new chat on `server`, in `profile` or the one its New Session uses, with `text` in
    /// the composer for the user to review; nothing is sent (#1402). The text and its destination
    /// wait in the app group's share inbox first, so a cold launch, a server switch or a sign-in
    /// can't lose them, and only the bare share link travels as the deep link. Each call is its
    /// own chat text, even for the same text. The Hermes home adds it to that Profile's new
    /// session draft, after any unsent text, then opens it with a review notice naming `origin`.
    /// Callers: the New Chat with Content intent, and About's Troubleshoot with Hermes (#1476).
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

/// "New Chat" — opens Hermex on the New Chat composer, mirroring the in-app "+" button
/// (no server session is created until the first message). Available to the Action button,
/// Shortcuts, Spotlight, and Siri via `HermexShortcuts`.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open Hermex on a new, empty chat.")

    /// Foregrounds the app so the navigation can run in-process.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.newChatURL)
        return .result()
    }
}

/// "New Chat with Voice" — opens Hermex on the New Chat composer and auto-starts voice
/// dictation, so an Action-button press starts a hands-free chat (no second tap on the mic).
/// Routes through the same `AppIntentRouter`/deep-link plumbing as `NewChatIntent`, but on a
/// distinct host so the composer knows to begin listening once it's on screen (issue #338).
/// Mic/speech permission is handled by the existing dictation path: if access is undetermined
/// the system prompt appears, and if it's denied the composer shows a clear error instead.
struct NewChatVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat with Voice"
    static var description = IntentDescription("Open Hermex on a new chat and start voice dictation.")

    /// Foregrounds the app so the navigation — and the microphone — can run in-process.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.newChatVoiceURL)
        return .result()
    }
}

/// "New Chat in <Profile>" — opens Hermex on a new chat pinned to a specific server profile
/// the user picks when configuring the Shortcut/Siri phrase (issue #339). The chosen
/// `ProfileEntity` is carried through the same `AppIntentRouter`/deep-link plumbing as the
/// other New Chat intents, on its own host (`new-chat-profile`) with the profile name as a
/// query item, so `PendingNewChatView` can create the session pinned to it. A Hermes server's
/// Profile (#1180) adds its server, and opens a new Hermes session there.
struct NewChatInProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat in Profile"
    static var description = IntentDescription("Open Hermex on a new chat pinned to a specific profile.")

    /// Foregrounds the app so the navigation can run in-process.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("New chat in \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let hermes = profile.hermesNewChat
        AppIntentRouter.shared.requestDeepLink(
            HermesDeepLink.newChatInProfileURL(profileName: hermes?.profile ?? profile.id, server: hermes?.server)
        )
        return .result()
    }
}

/// "New Chat with Content" — opens Hermex on a new chat with the Shortcut's text in the composer,
/// never sent (#1402): on a Hermes server's Profile, or the active Hermes server's New Session
/// Profile. A webui Profile can't take it.
struct NewChatWithContentIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat with Content"
    static var description = IntentDescription("Open Hermex on a new chat with this text in the composer. Nothing is sent until you send it.")

    /// Foregrounds the app so the user can review the text.
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
        let destination = try Self.destination(profile: profile, active: ProfileEntityProvider.savedServerURL(),
                                               servers: ServerRegistry.shared.servers)
        try AppIntentRouter.shared.openNewChat(prefilling: content, server: destination.server, profile: destination.profile)
        return .result()
    }

    /// The chosen Hermes Profile, else the active server when it is a Hermes server.
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

/// Why New Chat with Content opened nothing; Shortcuts shows the message.
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

/// Registers Hermex's App Shortcuts. iOS discovers this conformance automatically at build
/// time — it does not need to be referenced from the `App` struct. Exposing the intent here
/// is what makes "New Chat" appear in the Shortcuts app, Spotlight, and Siri, and assignable
/// to the iPhone Action button.
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

/// A new Hermes session a Shortcut asked for (#1180): New Chat or New Chat with Voice on the
/// active Hermes server, or New Chat in Profile on a Hermes server's Profile. `ContentView`
/// holds it until its server is active and signed in; that server's Sessions list then opens it.
struct HermesNewChatDestination: Hashable {
    let server: URL
    /// The Profile to start in; nil takes the one the Sessions list's New Session uses.
    let profile: String?
    var autoStartsVoiceInput = false
    /// Fresh per request, so running the same Shortcut again opens another chat.
    let id = UUID()

    enum Route: Equatable {
        /// The server isn't a configured Hermes server: the app opens as it is.
        case ignore
        case waitForSignIn
        /// Make the server active first; the rebuilt home takes the held request.
        case switchServer(ServerAccount)
        case open
    }

    init(server: URL, profile: String?, autoStartsVoiceInput: Bool = false) {
        self.server = server
        self.profile = profile
        self.autoStartsVoiceInput = autoStartsVoiceInput
    }

    /// Parses a Hermes Profile's `new-chat-profile?server=…&profile=…`. Nil for any other link,
    /// including a bare `new-chat-profile?profile=…`, which keeps its webui route (#971).
    init?(url: URL) {
        guard HermesDeepLink.isNewChatInProfileURL(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == HermesDeepLink.serverQueryItem })?.value,
              let server = Self.server(raw),
              let profile = HermesDeepLink.profileName(fromNewChatInProfile: url) else { return nil }
        self.init(server: server, profile: profile)
    }

    /// The server a Hermes Profile's id or link names: an absolute `http(s)` URL, as the registry
    /// stores it.
    static func server(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// New Chat and New Chat with Voice on the active server when it is a Hermes server, signed in
    /// or not; nil on a webui server, whose New Chat is unchanged.
    @MainActor static func onActiveServer(state: AuthManager.State, servers: [ServerAccount],
                                          autoStartsVoiceInput: Bool) -> Self? {
        guard let active = state.server,
              servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else { return nil }
        return Self(server: active, profile: nil, autoStartsVoiceInput: autoStartsVoiceInput)
    }

    /// Decided by the registry and auth state alone, as a session link is (`HermesSessionLinkRouter`).
    @MainActor func route(state: AuthManager.State, servers: [ServerAccount]) -> Route {
        guard let account = servers.first(where: { $0.id == server.absoluteString }), account.kind == .hermes else {
            return .ignore
        }
        guard state.server == server else { return .switchServer(account) }
        if case .loggedIn = state { return .open }
        return .waitForSignIn
    }

    /// The chat `entry`'s Sessions list opens: in this request's Profile, else `listed`, the one
    /// its New Session uses. Nil for another server's list, and until the list `isLive`, having
    /// read the host and showing no offline cache, whatever Profile the request names.
    @MainActor func chat(on entry: HermesSessionListEntry, listed: String?, isLive: Bool) -> HermesSessionChat? {
        guard entry.server == server, isLive, let profile = profile ?? listed else { return nil }
        return HermesSessionChat(server: server, connection: entry.connection, target: .new(profile: profile),
                                 autoStartsVoiceInput: autoStartsVoiceInput)
    }
}
