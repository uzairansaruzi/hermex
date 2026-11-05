import SwiftUI

/// Color scheme, text size, code display, the primary-button tint and the app icon (#1583). They
/// apply on this iPhone to every server; the header color is per server, on the server's page.
/// A real chat stays pinned on top, so each change shows without leaving the page.
struct SettingsAppearancePage: View {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppTextSize.storageKey) private var textSizeStop = 0
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?
    @AppStorage(CodeDisplaySettings.wrapsLinesKey) private var wrapsCodeLines = false
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            AppearancePreview()
            Divider()
            List {
                Section("Color Scheme") {
                    Picker("Color Scheme", selection: $appThemeRawValue) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Text") {
                    textSizeRow
                }

                Section("Code") {
                    Toggle(isOn: usesCustomCodeSize) {
                        SettingsLabel(title: String(localized: "Custom Code Size"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    if let customCodeSize {
                        customCodeSizeRow(customCodeSize)
                    }

                    Toggle(isOn: $wrapsCodeLines) {
                        SettingsLabel(
                            title: String(localized: "Wrap Lines"),
                            systemImage: "arrow.turn.down.left",
                            note: String(localized: "Or tap wrap in any code block.")
                        )
                    }
                }

                Section("More") {
                    Toggle(isOn: $tintsPrimaryActions) {
                        SettingsLabel(title: String(localized: "Tint New Chat & Send"), systemImage: "paintbrush.pointed")
                    }

                    NavigationLink {
                        ThinkingSliderPickerView()
                    } label: {
                        SettingsLabel(title: String(localized: "Thinking Slider"), systemImage: "slider.horizontal.below.rectangle")
                    }

                    AppIconSettingsSection()
                }
            }
        }
        .settingsPage(String(localized: "Appearance"))
        .onChange(of: textSizeStop) { AppTextSize.applyStoredSizeToConnectedScenes() }
    }

    private var textSizeRow: some View {
        VStack(spacing: 8) {
            LabeledContent {
                Text(textSizeValue)
            } label: {
                SettingsLabel(title: String(localized: "Text Size"), systemImage: "textformat.size")
            }

            Slider(
                value: Binding(get: { Double(textSizeStop) }, set: { textSizeStop = Int($0.rounded()) }),
                in: 0...Double(AppTextSize.stops.count - 1),
                step: 1
            )
            .accessibilityLabel("Text Size")
            .accessibilityValue(textSizeValue)
        }
    }

    private var textSizeValue: String {
        guard let size = AppTextSize.size(atStop: textSizeStop) else { return String(localized: "System") }
        return AppTextSize.percentage(of: size).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Turning it on starts at the size code is showing now, so nothing jumps.
    private var usesCustomCodeSize: Binding<Bool> {
        Binding {
            customCodeSize != nil
        } set: { isOn in
            let current = ChatTypography(dynamicTypeSize: dynamicTypeSize).codeSize.rounded()
            let range = CodeDisplaySettings.customSizeRange
            customCodeSize = isOn ? min(max(Double(current), range.lowerBound), range.upperBound) : nil
        }
    }

    private func customCodeSizeRow(_ size: Double) -> some View {
        let value = String(localized: "\(Int(size)) pt")
        return HStack(spacing: 12) {
            Slider(
                value: Binding(get: { size }, set: { customCodeSize = $0 }),
                in: CodeDisplaySettings.customSizeRange,
                step: 1
            )
            .accessibilityLabel("Custom Code Size")
            .accessibilityValue(value)

            Text(value)
                .font(AppFont.footnote())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// A short chat drawn by the transcript's own views, so it shows settings exactly as a chat will.
/// It scrolls but does nothing else. At accessibility text sizes the controls need the room, so
/// it takes less of the screen and drops the composer.
private struct AppearancePreview: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let question = ChatMessage(
        role: "user",
        content: String(localized: "Fix the login retry bug"),
        timestamp: nil,
        messageId: "appearance-preview-question"
    )
    private let reply = ChatMessage(
        role: "assistant",
        content: String(localized: "**Found the cause.** The retry loop never resets. See `AuthManager.swift`.") + """


        ```swift
        func retry(_ attempt: Int) async throws {
            guard attempt < limit else { throw RetryError.exhausted(after: attempt) }
        }
        ```
        """,
        timestamp: nil,
        messageId: "appearance-preview-reply"
    )
    private let toolCall = ToolCall(
        id: "appearance-preview-tool",
        name: "terminal",
        preview: "12 passed, 0 failed",
        args: nil,
        isCompleted: true
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                MessageBubbleView(message: question, transcriptMediaCacheNamespace: "appearance-preview")
                MessageBubbleView(message: reply, transcriptMediaCacheNamespace: "appearance-preview")
                ToolCallDetailBodyView(toolCall: toolCall, status: .success)
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                AppearancePreviewComposer()
            }
        }
        .containerRelativeFrame(.vertical) { height, _ in
            height * (dynamicTypeSize.isAccessibilitySize ? 0.26 : 0.42)
        }
        .background(Color(.systemBackground))
        // Sample text with nothing to act on; the controls below say what they changed.
        .accessibilityHidden(true)
    }
}

/// The composer at rest: its surface, placeholder and Send button colors, without its controls.
private struct AppearancePreviewComposer: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    var body: some View {
        let send = ChatComposerActionAppearance(
            isStop: false,
            isDisabled: false,
            colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions,
            themeHex: headerLogoColorHex
        )
        HStack {
            Text("Ask anything...")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(send.foreground)
                .frame(width: 32, height: 32)
                .background(send.background, in: Circle())
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .modifier(ChatComposerSurfaceStyle(isExpanded: false))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
