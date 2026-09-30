import SwiftUI
import SwiftData

struct HermexSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
    /// Opens the chat at a 1-based position in the visible list.
    let openChat: (_ position: Int) -> Void
    /// Opens the chat `offset` rows from the selected one, wrapping at the ends.
    let openAdjacentChat: (_ offset: Int) -> Void
}

private struct HermexSceneActionsKey: FocusedValueKey {
    typealias Value = HermexSceneActions
}

extension FocusedValues {
    var hermexSceneActions: HermexSceneActions? {
        get { self[HermexSceneActionsKey.self] }
        set { self[HermexSceneActionsKey.self] = newValue }
    }
}

struct HermexCommands: Commands {
    @FocusedValue(\.hermexSceneActions) private var focusedActions

    /// Every command is off while the app lock is up (#885). Read live, so a stale
    /// menu can't act either.
    @MainActor private var actions: HermexSceneActions? {
        AppLock.shared.isLocked ? nil : focusedActions
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                actions?.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.canCreateNewChat != true)
        }

        CommandGroup(after: .newItem) {
            Button("Search Sessions") {
                actions?.searchSessions()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }

        // View menu, beside Toggle Sidebar. ⌘⇧] and ⌘⇧[ back up ⌃Tab in case
        // iPadOS or a focused text view takes it first. Out-of-range positions
        // do nothing rather than grey out: counting rows here would filter and
        // sort every session on each update.
        CommandGroup(after: .sidebar) {
            Group {
                Button("Next Chat") { actions?.openAdjacentChat(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Chat") { actions?.openAdjacentChat(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Next Chat") { actions?.openAdjacentChat(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Chat") { actions?.openAdjacentChat(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(1...9, id: \.self) { position in
                    Button("Go to Chat \(position)") { actions?.openChat(position) }
                        .keyboardShortcut(KeyEquivalent(Character(String(position))), modifiers: .command)
                }
            }
            .disabled(actions == nil)
        }
    }
}

@main
struct HermesMobileApp: App {
    // APNs hands device tokens to a UIKit delegate and nowhere else.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    init() {
        // Record installation age even before a server has been configured.
        _ = RatingPromptState.shared
        NetworkPathMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Launch argument hook so the Streaming Lab can be opened without
            // UI navigation (agent-driven simulator diagnosis, issue #234):
            // `xcrun simctl launch <udid> com.uzairansar.hermesmobile --streaming-lab`
            if ProcessInfo.processInfo.arguments.contains("--streaming-lab") {
                NavigationStack {
                    StreamingLabView()
                }
            } else {
                ContentView(authManager: authManager)
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
                    // Signs in from `HERMEX_DEV_*` launch environment variables
                    // (`scripts/sim-login`); a no-op when they are absent.
                    .task(id: authManager.state) { await DevAutoLogin.run(authManager: authManager) }
                    .overlay(alignment: .topLeading) {
                        // `--hitch-meter`: frame-hitch readout for profiling (#870).
                        if HitchMeter.isEnabled {
                            HitchMeterOverlay()
                        }
                    }
            }
            #else
            ContentView(authManager: authManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            #endif
        }
        .modelContainer(for: [CachedSession.self, CachedMessage.self])
        .commands {
            HermexCommands()
            SidebarCommands()
        }
    }
}
