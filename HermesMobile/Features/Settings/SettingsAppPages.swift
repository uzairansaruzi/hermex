import SwiftUI

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
                    SettingsLabel(title: String(localized: "Tint New Chat & Send"), systemImage: "paintbrush.pointed")
                }
            }

            #if !targetEnvironment(macCatalyst)
            Section {
                AppIconSettingsSection()
            }
            #endif
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

    private var dictationNote: String? {
        #if targetEnvironment(macCatalyst)
        nil
        #else
        String(localized: "On-device only keeps audio on this iPhone.")
        #endif
    }

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

                #if !targetEnvironment(macCatalyst)
                Toggle(isOn: $dismissKeyboardAfterSend) {
                    SettingsLabel(title: String(localized: "Dismiss keyboard after sending"), systemImage: "keyboard.chevron.compact.down")
                }
                #endif
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
                        note: dictationNote
                    )
                }
            }

            Section {
                Toggle(isOn: $showsChatFilesButton) {
                    SettingsLabel(title: String(localized: "Files Button"), systemImage: "folder")
                }

                Toggle(isOn: $showsChatGitControls) {
                    SettingsLabel(title: String(localized: "Git Actions"), systemImage: "arrow.triangle.branch")
                }
            }
        }
        .settingsPage(String(localized: "Composer"))
    }
}

/// How a chat's transcript shows turns, details, and long lines.
struct SettingsChatPage: View {
    @AppStorage(ChatTranscriptDisplaySettings.thinkingAndToolCardsKey) private var thinkingAndToolCards = ThinkingAndToolCards.collapsed
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
                Picker(selection: $thinkingAndToolCards) {
                    ForEach(ThinkingAndToolCards.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Thinking & Tools"), systemImage: "brain.head.profile")
                }

                Toggle(isOn: $foldsSettledTurns) {
                    SettingsLabel(
                        title: String(localized: "Fold Finished Turns"),
                        systemImage: "rectangle.compress.vertical",
                        note: String(localized: "Collapses a finished turn behind one row.")
                    )
                }

                Picker(selection: $completionPositionRawValue) {
                    ForEach(SessionChatPreferences.CompletionPosition.allCases, id: \.rawValue) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Position after response completes"), systemImage: "text.alignleft")
                }
            }

            Section {
                Toggle(isOn: $showsAssistantTurnTimestamps) {
                    SettingsLabel(title: String(localized: "Message Timestamps"), systemImage: "clock")
                }

                Toggle(isOn: $showsResponseSpeed) {
                    SettingsLabel(title: String(localized: "Response Speed"), systemImage: "gauge.with.dots.needle.67percent")
                }

                Toggle(isOn: $hidesAttachmentPaths) {
                    SettingsLabel(
                        title: String(localized: "Hide Attachment Paths"),
                        systemImage: "eye.slash",
                        note: String(localized: "The server still receives them.")
                    )
                }
            }

            Section {
                Toggle(isOn: $wrapsCodeBlockLines) {
                    SettingsLabel(
                        title: String(localized: "Wrap Code Block Lines"),
                        systemImage: "arrow.turn.down.left",
                        note: String(localized: "Or tap wrap in any code block.")
                    )
                }

                Toggle(isOn: $rtlChatLayoutEnabled) {
                    SettingsLabel(
                        title: String(localized: "Right-to-Left Chat Layout"),
                        systemImage: "text.alignright",
                        note: String(localized: "Messages and the composer only; code stays left-to-right.")
                    )
                }
            }
        }
        .settingsPage(String(localized: "Chat"))
    }
}

/// Haptics and the app lock.
struct SettingsGeneralPage: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(AppHaptics.streamingPulseIsEnabledKey) private var isStreamingPulseEnabled = false

    var body: some View {
        List {
            #if !targetEnvironment(macCatalyst)
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
            #endif

            AppLockSection()
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
                ? String(localized: "Notifications, Live Activities and sharing still show content.")
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
