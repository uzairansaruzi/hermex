import SwiftUI
import SwiftData

struct HermexSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
    let openChat: (_ position: Int) -> Void
    let openAdjacentChat: (_ offset: Int) -> Void
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

    @MainActor private var actions: HermexSceneActions? {
        AppLock.shared.isLocked ? nil : focusedActions
    }

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
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    private let cacheContainer: ModelContainer

    init() {
        LaunchSignpost.begin()
        cacheContainer = CacheContainer.open()
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
                .task(id: authManager.state) { await DevAutoLogin.run(authManager: authManager) }
                .overlay(alignment: .topLeading) {
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
