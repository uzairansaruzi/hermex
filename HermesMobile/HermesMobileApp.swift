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
    /// Opens the selected bot's Screen; nil while there is none to open.
    var openScreen: (() -> Void)?
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

    /// The Screen of the chat on screen (`ScreenShortcut`, #1633), wherever it was pushed from, or
    /// with no chat on screen the Bots home's selected bot. Off while the app lock is up, as every command is.
    @MainActor private var openScreen: (() -> Void)? {
        guard !AppLock.shared.isLocked else { return nil }
        let shortcut = ScreenShortcut.shared
        guard shortcut.hasChat else { return focusedActions?.openScreen }
        return shortcut.opener.map { opener in { opener(takingOver: false) } }
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

        CommandGroup(after: .sidebar) {
            Button("Open Screen") { openScreen?() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(openScreen == nil)
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
    private let cacheContainer: ModelContainer

    init() {
        LaunchSignpost.begin()
        cacheContainer = CacheContainer.open()
        // Record installation age even before a server has been configured.
        _ = RatingPromptState.shared
        ChatTranscriptDisplaySettings.migrateThinkingAndToolCards()
        CodeDisplaySettings.migrateWrapSetting()
        AppBarFont.applyAtLaunch()
        NetworkPathMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            ContentView(authManager: authManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
                .background(WindowBackgroundPainter())
                .appRootFont()
                // Signs in from `HERMEX_DEV_*` launch environment variables
                // (`scripts/sim-login`); a no-op when they are absent.
                .task(id: authManager.state) { await DevAutoLogin.run(authManager: authManager) }
                .overlay(alignment: .topLeading) {
                    // `--hitch-meter`: frame-hitch readout for profiling (#870).
                    if HitchMeter.isEnabled {
                        HitchMeterOverlay()
                    }
                }
            #else
            ContentView(authManager: authManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
                .background(WindowBackgroundPainter())
                .appRootFont()
            #endif
        }
        .modelContainer(cacheContainer)
        .commands {
            HermexCommands()
            SidebarCommands()
        }
    }
}

/// Paints the window behind SwiftUI's content, which shows in the gap while a rotation outruns the
/// content's layout (#1528). A window has no background of its own, so that gap flashes black.
/// Also gives the window the accent, which SwiftUI's default tint and UIKit's controls both read.
private struct WindowBackgroundPainter: UIViewRepresentable {
    final class PaintingView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.backgroundColor = .appCanvas
            window?.tintColor = .appAccent
        }
    }

    func makeUIView(context: Context) -> PaintingView { PaintingView() }
    func updateUIView(_ view: PaintingView, context: Context) {}
}
