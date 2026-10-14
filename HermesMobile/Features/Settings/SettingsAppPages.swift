import SwiftUI
import UIKit

// The Hermex pages on the Settings index (#1252). Each applies on this iPhone to every server.

/// Theme, app icon, and the primary-button tint. The header color is per server, on the
/// server's page.
struct SettingsAppearancePage: View {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false

    var body: some View {
        List {
            Section {
                Picker(selection: $appThemeRawValue) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Theme"), systemImage: "circle.lefthalf.filled")
                }

                Toggle(isOn: $tintsPrimaryActions) {
                    SettingsLabel(
                        title: String(localized: "Tint New Chat & Send"),
                        systemImage: "paintbrush.pointed",
                        note: String(localized: "Apply your header color to these primary buttons.")
                    )
                }
            }

            Section {
                AppIconSettingsSection()
            }
        }
        .settingsPage(String(localized: "Appearance"))
    }
}

/// How the composer sends, dictates, and which buttons it shows.
struct SettingsComposerPage: View {
    @AppStorage(StreamingSendBehavior.storageKey) private var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(SessionChatPreferences.dismissKeyboardKey) private var dismissKeyboardAfterSend = false
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(SectionVisibilitySettings.chatFilesKey) private var showsChatFilesButton = true
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsChatGitControls = true

    var body: some View {
        List {
            Section {
                Picker(selection: $streamingSendBehaviorRawValue) {
                    ForEach(StreamingSendBehavior.allCases) { behavior in
                        Text(behavior.settingsDescription).tag(behavior.rawValue)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Send While Responding"),
                        systemImage: "arrow.up.message",
                        note: String(localized: "Long-press Send to choose for one message.")
                    )
                }

                Toggle(isOn: $dismissKeyboardAfterSend) {
                    SettingsLabel(title: String(localized: "Dismiss keyboard after sending"), systemImage: "keyboard.chevron.compact.down")
                }
            }

            Section {
                Picker(selection: $sttProviderPreferenceRawValue) {
                    ForEach(ComposerSTTProviderPreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Dictation Provider"),
                        systemImage: "mic",
                        note: String(localized: "On-device only keeps composer dictation audio off your Hermes server.")
                    )
                }
            }

            Section {
                Toggle(isOn: $showsChatFilesButton) {
                    SettingsLabel(title: String(localized: "Files Button"), systemImage: "folder")
                }

                Toggle(isOn: $showsChatGitControls) {
                    SettingsLabel(
                        title: String(localized: "Git Actions"),
                        systemImage: "arrow.triangle.branch",
                        note: String(localized: "Hides the git menu, branch picker, and commit controls.")
                    )
                }
            }
        }
        .settingsPage(String(localized: "Composer"))
    }
}

/// How a chat's transcript shows turns, details, and long lines.
struct SettingsChatPage: View {
    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsThinkingAndToolCards = true
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var thinkingCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var toolCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.foldsSettledTurnsKey) private var foldsSettledTurns = true
    @AppStorage(SessionChatPreferences.completionPositionKey) private var completionPositionRawValue = SessionChatPreferences.CompletionPosition.latest.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) private var showsAssistantTurnTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps
    @AppStorage(ChatTranscriptDisplaySettings.showsResponseSpeedKey) private var showsResponseSpeed = false
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) private var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(ChatTranscriptDisplaySettings.hidesAttachmentPathsKey) private var hidesAttachmentPaths = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showsThinkingAndToolCards) {
                    SettingsLabel(title: String(localized: "Thinking and Tool Cards"), systemImage: "brain.head.profile")
                }

                Toggle(isOn: $thinkingCardsStartExpanded) {
                    SettingsLabel(title: String(localized: "Expand Thinking by Default"), systemImage: "rectangle.expand.vertical")
                }

                Toggle(isOn: $toolCardsStartExpanded) {
                    SettingsLabel(title: String(localized: "Expand Tools by Default"), systemImage: "wrench.and.screwdriver")
                }
            } footer: {
                Text("Thinking and Tool cards start expanded instead of collapsed. Tapping a card still toggles it.")
            }

            Section {
                Toggle(isOn: $foldsSettledTurns) {
                    SettingsLabel(
                        title: String(localized: "Fold Finished Turns"),
                        systemImage: "rectangle.compress.vertical",
                        note: String(localized: "Collapses a finished turn's thinking, tool calls, and interim replies behind one row that shows how long it took. Tap the row to expand it.")
                    )
                }

                Picker(selection: $completionPositionRawValue) {
                    ForEach(SessionChatPreferences.CompletionPosition.allCases, id: \.rawValue) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Position after response completes"),
                        systemImage: "text.alignleft",
                        note: String(localized: "Applies to Sessions on this device.")
                    )
                }
            }

            Section {
                Toggle(isOn: $showsAssistantTurnTimestamps) {
                    SettingsLabel(
                        title: String(localized: "Message Timestamps"),
                        systemImage: "clock",
                        note: String(localized: "Shows the time under your messages and under each finished response.")
                    )
                }

                Toggle(isOn: $showsResponseSpeed) {
                    SettingsLabel(title: String(localized: "Response Speed"), systemImage: "gauge.with.dots.needle.67percent")
                }

                Toggle(isOn: $hidesAttachmentPaths) {
                    SettingsLabel(
                        title: String(localized: "Hide Attachment Paths"),
                        systemImage: "eye.slash",
                        note: String(localized: "Hides the appended file-path line in your sent messages. Attachments still appear as previews, and the server still receives the paths.")
                    )
                }
            }

            Section {
                Toggle(isOn: $wrapsCodeBlockLines) {
                    SettingsLabel(
                        title: String(localized: "Wrap Code Block Lines"),
                        systemImage: "arrow.turn.down.left",
                        note: String(localized: "Wraps long lines in code blocks to fit the screen instead of scrolling sideways. You can also tap the wrap button in any code block.")
                    )
                }

                Toggle(isOn: $rtlChatLayoutEnabled) {
                    SettingsLabel(
                        title: String(localized: "Right-to-Left Chat Layout"),
                        systemImage: "text.alignright",
                        note: String(localized: "Lays out messages and the composer right-to-left for Arabic, Hebrew, Persian, and Urdu. Code, math, tables, and tool output stay left-to-right. Other screens are unaffected.")
                    )
                }
            }
        }
        .settingsPage(String(localized: "Chat"))
    }
}

/// Haptics, the app lock, and Siri & Shortcuts.
struct SettingsGeneralPage: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(AppHaptics.streamingPulseIsEnabledKey) private var isStreamingPulseEnabled = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $isHapticsEnabled) {
                    SettingsLabel(title: String(localized: "Haptic Feedback"), systemImage: "iphone.radiowaves.left.and.right")
                }

                if isHapticsEnabled {
                    Toggle(isOn: $isStreamingPulseEnabled) {
                        SettingsLabel(
                            title: String(localized: "Pulse While Streaming"),
                            systemImage: "waveform",
                            note: String(localized: "A light tick as each reply streams in.")
                        )
                    }
                }
            }

            AppLockSection()

            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Section {
                    SettingsExternalLink(
                        title: String(localized: "Open Hermex Settings"),
                        systemImage: "gearshape",
                        destination: settingsURL
                    )
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("Run Hermex actions like New Chat from Siri, Spotlight, the Lock Screen, or the iPhone Action button. Open Hermex Settings to manage its Siri & Search options. To assign an action to the Action button, open the iOS Settings app, choose Action Button, then Shortcut, and pick a Hermex action.")
                }
            }
        }
        .settingsPage(String(localized: "General"))
    }
}

/// The app lock toggle (#885), app-wide rather than per server. `AppLock` authenticates
/// before it changes, so the switch moves only once iOS says yes.
private struct AppLockSection: View {
    @Environment(\.scenePhase) private var scenePhase
    private let lock = AppLock.shared

    var body: some View {
        let capability = lock.capability

        Section {
            Toggle(isOn: Binding(get: { lock.isEnabled }, set: { isOn in Task { await lock.setEnabled(isOn) } })) {
                SettingsLabel(title: title(for: capability.method), systemImage: capability.method.systemImage)
            }
            // Without a passcode it can still be turned off: nothing could unlock it anyway.
            .disabled(lock.isAuthenticating || (!capability.hasPasscode && !lock.isEnabled))
            .onAppear { lock.refreshCapability() }
            .onChange(of: scenePhase) { _, phase in
                // The passcode or Face ID may have changed in iOS Settings.
                if phase == .active { lock.refreshCapability() }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(capability.hasPasscode
                ? String(localized: "Locks Hermex when it opens and after a minute away. Notifications, Live Activities and the share sheet still show their content.")
                : String(localized: "Set a passcode in iOS Settings to use this."))
        }
    }

    private func title(for method: AppLockCapability.Method) -> String {
        switch method {
        case .faceID: String(localized: "Require Face ID")
        case .touchID: String(localized: "Require Touch ID")
        case .passcode: String(localized: "Require Passcode")
        }
    }
}
