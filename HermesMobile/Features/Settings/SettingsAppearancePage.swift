import SwiftUI

/// Color scheme, theme, accent, text size, code display, the primary-button tint and the app icon
/// (#1583). They apply on this iPhone to every server; the header color is per server, on the
/// server's page. The Text and Code sections each open with a sample, so a change shows beside
/// its control.
struct SettingsAppearancePage: View {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppAppearanceSettings.lightThemeKey) private var lightTheme = ColorTheme.default
    @AppStorage(AppAppearanceSettings.darkThemeKey) private var darkTheme = ColorTheme.default
    @AppStorage(AppAppearanceSettings.accentHexKey) private var accentHex: String?
    @AppStorage(AppTextSize.storageKey) private var textSizeStop = 0
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?
    @AppStorage(CodeDisplaySettings.wrapsLinesKey) private var wrapsCodeLines = false
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AppList {
            Section("Color Scheme") {
                Picker("Color Scheme", selection: $appThemeRawValue) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Theme") {
                ThemePicker(lightTheme: $lightTheme, darkTheme: $darkTheme)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section("Accent") {
                AccentPicker(accentHex: $accentHex, lightTheme: lightTheme, darkTheme: darkTheme)
            }

            Section("Text") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The quick brown fox jumps over the lazy dog.")
                    Text("Messages, labels, and headings scale with this size.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                }
                .listRowSeparator(.hidden)

                textSizeRow

                Picker("Font", selection: Bindable(AppFontSettings.shared).family) {
                    ForEach(AppFontFamily.allCases) { Text(verbatim: $0.title).tag($0) }
                }
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
        .onChange(of: lightTheme) { AppAppearanceSettings.applyStoredToConnectedScenes() }
        .onChange(of: darkTheme) { AppAppearanceSettings.applyStoredToConnectedScenes() }
        .onChange(of: accentHex) { AppAppearanceSettings.applyStoredToConnectedScenes() }
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
                Text(verbatim: "A").font(AppFont.fixed(size: 13))
            } maximumValueLabel: {
                Text(verbatim: "A").font(AppFont.fixed(size: 22))
            }
            .foregroundStyle(.appSecondary)
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
                .foregroundStyle(.appSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// One card per theme. A card sets both modes; its light or dark orb sets only that mode.
private struct ThemePicker: View {
    @Binding var lightTheme: ColorTheme
    @Binding var darkTheme: ColorTheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            ForEach(ColorTheme.allCases) { theme in
                ThemeCard(theme: theme, lightTheme: $lightTheme, darkTheme: $darkTheme)
            }
        }
    }
}

private struct ThemeCard: View {
    let theme: ColorTheme
    @Binding var lightTheme: ColorTheme
    @Binding var darkTheme: ColorTheme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                orb(isDark: false, isSelected: lightTheme == theme)
                orb(isDark: true, isSelected: darkTheme == theme)
            }
            Button(action: selectBothModes) {
                Text(theme.title)
                    .font(AppFont.footnote(weight: lightTheme == theme && darkTheme == theme ? .semibold : .regular))
                    .foregroundStyle(.appPrimary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(theme.title)
            .accessibilityHint("Sets light and dark")
            .accessibilityAddTraits(lightTheme == theme && darkTheme == theme ? .isSelected : [])
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(.appGroupedSurface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The rest of the card. The orbs and title are buttons, so they answer first.
        .onTapGesture(perform: selectBothModes)
    }

    private func selectBothModes() {
        lightTheme = theme
        darkTheme = theme
    }

    private func orb(isDark: Bool, isSelected: Bool) -> some View {
        let palette = theme.palette(isDark: isDark)
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        func color(_ color: UIColor) -> Color { Color(uiColor: color.resolvedColor(with: traits)) }
        return Button {
            if isDark { darkTheme = theme } else { lightTheme = theme }
        } label: {
            Circle()
                .fill(color(palette.canvas))
                .overlay {
                    Circle().fill(
                        RadialGradient(
                            colors: [color(palette.accent), color(palette.accent).opacity(0)],
                            center: UnitPoint(x: 0.68, y: 0.26),
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                }
                .overlay { Circle().strokeBorder(Color(.appSeparator), lineWidth: 1) }
                .frame(width: 40, height: 40)
                .padding(3)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color(.appAccent), lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDark ? String(localized: "\(theme.title), dark") : String(localized: "\(theme.title), light"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The theme's own accent, eight swatches, or a custom color. A pick is shown as chosen; the app
/// uses it moved just far enough to stay readable (`ThemePalette.withAccent`).
private struct AccentPicker: View {
    private struct Swatch: Identifiable {
        let hex: String
        let name: String
        var id: String { hex }
    }

    private static let swatches = [
        Swatch(hex: "#0A84FF", name: String(localized: "Blue")),
        Swatch(hex: "#7D7AFF", name: String(localized: "Indigo")),
        Swatch(hex: "#30B8C4", name: String(localized: "Teal")),
        Swatch(hex: "#4CC96B", name: String(localized: "Green")),
        Swatch(hex: "#F4C63C", name: String(localized: "Yellow")),
        Swatch(hex: "#FF9F3C", name: String(localized: "Orange")),
        Swatch(hex: "#FF5C5C", name: String(localized: "Red")),
        Swatch(hex: "#FF6FAE", name: String(localized: "Pink"))
    ]

    @Binding var accentHex: String?
    let lightTheme: ColorTheme
    let darkTheme: ColorTheme

    @Environment(\.colorScheme) private var colorScheme

    /// The swatch for no pick, so it shows the accent that choosing it brings back.
    private var themeAccent: Color {
        let isDark = colorScheme == .dark
        return Color(uiColor: (isDark ? darkTheme : lightTheme).palette(isDark: isDark).accent)
    }

    private var customColor: Binding<Color> {
        Binding {
            accentHex.flatMap(Color.init(hexRGB:)) ?? Color(.appAccent)
        } set: { color in
            accentHex = HeaderLogoColor.hexString(from: color)
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
            swatch(
                fill: themeAccent,
                isSelected: accentHex == nil,
                label: String(localized: "Theme accent")
            ) { accentHex = nil }

            ForEach(Self.swatches) { swatch in
                self.swatch(
                    fill: Color(hexRGB: swatch.hex) ?? .clear,
                    isSelected: accentHex == swatch.hex,
                    label: swatch.name
                ) { accentHex = swatch.hex }
            }

            ColorPicker("Custom Color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 40)
        }
        .padding(.vertical, 4)
    }

    private func swatch(fill: Color, isSelected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 28, height: 28)
                .padding(4)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color(.appText), lineWidth: 2) }
                }
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                        .foregroundStyle(.appSecondary)
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
