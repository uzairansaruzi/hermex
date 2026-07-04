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
}

/// "New Chat" — opens Hermex on the New Chat composer, mirroring the in-app "+" button
/// (no server session is created until the first message). Available to the Action button,
/// Shortcuts, Spotlight, and Siri via `HermexShortcuts`.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open Zora on a new, empty chat.")

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
    static var description = IntentDescription("Open Zora on a new chat and start voice dictation.")

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
/// query item, so `PendingNewChatView` can create the session pinned to it.
struct NewChatInProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat in Profile"
    static var description = IntentDescription("Open Zora on a new chat pinned to a specific profile.")

    /// Foregrounds the app so the navigation can run in-process.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("New chat in \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.shared.requestDeepLink(
            HermesDeepLink.newChatInProfileURL(profileName: profile.id)
        )
        return .result()
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
    }
}
