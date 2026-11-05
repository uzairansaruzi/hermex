import SwiftUI

/// Color scheme, text size, code display, the primary-button tint and the app icon (#1583). They
/// apply on this iPhone to every server; the header color is per server, on the server's page.
/// The Text and Code sections each open with a sample, so a change shows beside its control.
struct SettingsAppearancePage: View {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppTextSize.storageKey) private var textSizeStop = 0
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?
    @AppStorage(CodeDisplaySettings.wrapsLinesKey) private var wrapsCodeLines = false
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("The quick brown fox jumps over the lazy dog.")
                    Text("Messages, labels, and headings scale with this size.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)

                textSizeRow
            }

            Section("Code") {
                AppearanceCodePreview()
                    .listRowSeparator(.hidden)

                Toggle(isOn: usesCustomCodeSize) {
                    SettingsLabel(title: String(localized: "Custom Code Size"), systemImage: "chevron.left.forwardslash.chevron.right")
                }

                if let customCodeSize {
                    customCodeSizeRow(customCodeSize)
                }

                Toggle(isOn: $wrapsCodeLines) {
                    SettingsLabel(title: String(localized: "Wrap Lines"), systemImage: "arrow.turn.down.left")
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
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text(verbatim: "A").font(.system(size: 13))
            } maximumValueLabel: {
                Text(verbatim: "A").font(.system(size: 22))
            }
            .foregroundStyle(.secondary)
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

/// A few lines of code in the chat's own highlighter and font, following both Code settings.
private struct AppearanceCodePreview: View {
    private static let code = """
    func retry(_ attempt: Int) async throws {
        guard attempt < limit else { throw RetryError.exhausted(after: attempt) }
    }
    """

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?
    @AppStorage(CodeDisplaySettings.wrapsLinesKey) private var wrapsLines = false
    @State private var highlight: (request: MarkdownCodeHighlightRequest, text: NSAttributedString)?

    private var request: MarkdownCodeHighlightRequest {
        MarkdownCodeHighlightRequest(code: Self.code, language: "swift", colorScheme: colorScheme, isStreaming: false)
    }

    var body: some View {
        Group {
            if wrapsLines {
                lines
            } else {
                ScrollView(.horizontal) {
                    lines.fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            }
        }
        .font(ChatTypography(dynamicTypeSize: dynamicTypeSize).codeFont(customSize: customCodeSize))
        .forcedLeftToRight()
        .accessibilityHidden(true)
        .task(id: request) {
            let request = request
            if case .highlighted(let text) = await MarkdownCodeHighlighter.shared.highlightedCode(for: request),
               !Task.isCancelled {
                highlight = (request, text)
            }
        }
    }

    private var lines: some View {
        // Plain until this color scheme's highlight is ready, never the other scheme's colors.
        let current = highlight?.request == request ? highlight?.text : nil
        let content = MarkdownCodeHighlighter.shared.cachedHighlight(for: request)
            ?? current
            ?? NSAttributedString(string: Self.code)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(MarkdownAttributedCodeFormatter.lines(in: content)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(line.id + 1)")
                        .foregroundStyle(.secondary)
                    line.segments.reduce(Text(verbatim: "")) { partial, segment in
                        partial + Text(AttributedString(segment.attributedText))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
