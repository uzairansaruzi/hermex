import SwiftUI
import SwiftData

struct HermexSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
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
    @FocusedValue(\.hermexSceneActions) private var actions

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
    }
}

@main
struct HermesMobileApp: App {
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Launch argument hooks for deterministic, server-free visual QA.
            if ProcessInfo.processInfo.arguments.contains("--chat-theme-lab") {
                NavigationStack {
                    ChatThemeLabView()
                }
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            } else if ProcessInfo.processInfo.arguments.contains("--model-picker-capture") {
                ModelPickerCaptureHost()
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
                    .onAppear { applyModelPickerCapturePaletteIfRequested() }
            } else if ProcessInfo.processInfo.arguments.contains("--surface-gallery") {
                NavigationStack {
                    SurfaceGalleryView()
                }
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            } else if ProcessInfo.processInfo.arguments.contains("--streaming-lab") {
                NavigationStack {
                    StreamingLabView()
                }
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            } else {
                ContentView(authManager: authManager)
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
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
    #if DEBUG
    private func applyModelPickerCapturePaletteIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--model-picker-palette"),
              arguments.index(after: index) < arguments.endIndex,
              let temperature = ChatPaletteTemperature(
                rawValue: arguments[arguments.index(after: index)]
              )
        else { return }
        UserDefaults.standard.set(temperature.rawValue, forKey: ChatPaletteTemperature.storageKey)
    }

    #endif
}
