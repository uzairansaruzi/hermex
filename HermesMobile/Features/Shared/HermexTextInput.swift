import SwiftUI

private enum HermexTextInputMetrics {
    static let minimumFieldHeight: CGFloat = 44
    static let codeBoxHeight: CGFloat = 48
    static let maximumCodeBoxWidth: CGFloat = 48
}

private enum HermexTextInputColors {
    static let surface = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s100,
        dark: HermesColorRamp.Neutral.s900
    )
    static let error = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Red.s700,
        dark: HermesColorRamp.Red.s400
    )
}

/// Canonical Hermex field chrome shared by native text, secure, and code editors.
private struct HermexTextInputShell<Editor: View>: View {
    let label: LocalizedStringKey
    let helperText: Text?
    let errorText: Text?
    let isEnabled: Bool
    let showsFieldChrome: Bool
    private let editor: (FocusState<Bool>.Binding) -> Editor

    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        label: LocalizedStringKey,
        helperText: Text?,
        errorText: Text?,
        isEnabled: Bool,
        showsFieldChrome: Bool = true,
        @ViewBuilder editor: @escaping (FocusState<Bool>.Binding) -> Editor
    ) {
        self.label = label
        self.helperText = helperText
        self.errorText = errorText
        self.isEnabled = isEnabled
        self.showsFieldChrome = showsFieldChrome
        self.editor = editor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HermesSpacing.s8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            fieldContent

            if let errorText {
                errorText
                    .font(.footnote)
                    .foregroundStyle(HermexTextInputColors.error)
            } else if let helperText {
                helperText
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled {
                isFocused = false
            }
        }
    }

    @ViewBuilder
    private var fieldContent: some View {
        if showsFieldChrome {
            editor($isFocused)
                .padding(.horizontal, HermesSpacing.s12)
                .frame(minHeight: HermexTextInputMetrics.minimumFieldHeight)
                .background(HermexTextInputColors.surface, in: fieldShape)
                .overlay {
                    fieldShape
                        .stroke(borderColor, lineWidth: borderWidth)
                        .allowsHitTesting(false)
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
        } else {
            editor($isFocused)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HermesRadius.field, style: .continuous)
    }

    private var borderColor: Color {
        if errorText != nil {
            return HermexTextInputColors.error
        }
        if colorSchemeContrast == .increased {
            return HermexSurfaceBorderColors.increasedContrast
        }
        return isFocused ? HermexSurfaceBorderColors.focused : HermexSurfaceBorderColors.resting
    }

    private var borderWidth: CGFloat {
        isFocused || errorText != nil || colorSchemeContrast == .increased ? 1.5 : 1
    }
}

struct HermexTextField: View {
    private let label: LocalizedStringKey
    @Binding private var text: String
    private let prompt: Text?
    private let helperText: Text?
    private let errorText: Text?
    private let isEnabled: Bool

    init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: Text? = nil,
        helperText: Text? = nil,
        errorText: Text? = nil,
        isEnabled: Bool = true
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.helperText = helperText
        self.errorText = errorText
        self.isEnabled = isEnabled
    }

    var body: some View {
        HermexTextInputShell(
            label: label,
            helperText: helperText,
            errorText: errorText,
            isEnabled: isEnabled
        ) { focus in
            TextField(label, text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .focused(focus)
                .accessibilityHint(errorText ?? helperText ?? Text(""))
        }
    }
}

struct HermexSecureField: View {
    private let label: LocalizedStringKey
    @Binding private var text: String
    private let prompt: Text?
    private let helperText: Text?
    private let errorText: Text?
    private let isEnabled: Bool

    init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        prompt: Text? = nil,
        helperText: Text? = nil,
        errorText: Text? = nil,
        isEnabled: Bool = true
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.helperText = helperText
        self.errorText = errorText
        self.isEnabled = isEnabled
    }

    var body: some View {
        HermexTextInputShell(
            label: label,
            helperText: helperText,
            errorText: errorText,
            isEnabled: isEnabled
        ) { focus in
            SecureField(label, text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .focused(focus)
                .accessibilityHint(errorText ?? helperText ?? Text(""))
        }
    }
}

enum HermexCodeInputNormalizer {
    static func normalize(_ value: String, length: Int) -> String {
        precondition((4...8).contains(length), "HermexCodeInput length must be between 4 and 8")
        let asciiDigits = value.filter { character in
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                return false
            }
            return (48...57).contains(scalar.value)
        }
        return String(asciiDigits.prefix(length))
    }
}

enum HermexCodeInputLayout {
    static func spacing(for length: Int) -> CGFloat {
        precondition((4...8).contains(length), "HermexCodeInput length must be between 4 and 8")
        return length >= 7 ? HermesSpacing.s4 : HermesSpacing.s8
    }

    static func boxWidth(containerWidth: CGFloat, length: Int) -> CGFloat {
        precondition((4...8).contains(length), "HermexCodeInput length must be between 4 and 8")
        let totalSpacing = spacing(for: length) * CGFloat(length - 1)
        let availableWidth = max(0, containerWidth - totalSpacing)
        return min(HermexTextInputMetrics.maximumCodeBoxWidth, availableWidth / CGFloat(length))
    }
}

struct HermexCodeInput: View {
    private let label: LocalizedStringKey
    @Binding private var code: String
    private let length: Int
    private let helperText: Text?
    private let errorText: Text?
    private let isEnabled: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    // Relative to the same .title3 style the digit glyphs render in, so the boxes and their
    // containing row grow with Dynamic Type instead of clipping accessibility-sized text against a
    // fixed 48pt frame. Defaults to exactly the existing 48pt baseline at the standard content size.
    @ScaledMetric(relativeTo: .title3) private var scaledCodeBoxHeight: CGFloat = HermexTextInputMetrics.codeBoxHeight

    init(
        _ label: LocalizedStringKey,
        code: Binding<String>,
        length: Int = 6,
        helperText: Text? = nil,
        errorText: Text? = nil,
        isEnabled: Bool = true
    ) {
        precondition((4...8).contains(length), "HermexCodeInput length must be between 4 and 8")
        self.label = label
        self._code = code
        self.length = length
        self.helperText = helperText
        self.errorText = errorText
        self.isEnabled = isEnabled
    }

    var body: some View {
        HermexTextInputShell(
            label: label,
            helperText: helperText,
            errorText: errorText,
            isEnabled: isEnabled,
            showsFieldChrome: false
        ) { focus in
            GeometryReader { proxy in
                let spacing = HermexCodeInputLayout.spacing(for: length)
                let boxWidth = HermexCodeInputLayout.boxWidth(
                    containerWidth: proxy.size.width,
                    length: length
                )

                ZStack {
                    HStack(spacing: spacing) {
                        ForEach(0..<length, id: \.self) { index in
                            codeBox(at: index, width: boxWidth, isFocused: focus.wrappedValue)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                    TextField("", text: normalizedCode)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .focused(focus)
                        .accessibilityLabel(Text(label))
                        .accessibilityValue(Text(accessibilityValue))
                        .accessibilityHint(accessibilityHint)
                }
            }
            .frame(height: scaledCodeBoxHeight)
        }
        .onAppear(perform: normalizeBoundCode)
        .onChange(of: code) { _ in
            normalizeBoundCode()
        }
    }

    private var normalizedCode: Binding<String> {
        Binding(
            get: { code },
            set: { code = HermexCodeInputNormalizer.normalize($0, length: length) }
        )
    }

    private var normalizedCharacters: [Character] {
        Array(HermexCodeInputNormalizer.normalize(code, length: length))
    }

    @ViewBuilder
    private func codeBox(at index: Int, width: CGFloat, isFocused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: HermesRadius.control, style: .continuous)
        Text(index < normalizedCharacters.count ? String(normalizedCharacters[index]) : "")
            .font(.title3.monospacedDigit().weight(.semibold))
            .frame(width: width, height: scaledCodeBoxHeight)
            .background(HermexTextInputColors.surface, in: shape)
            .overlay {
                shape
                    .stroke(
                        boxBorderColor(isFocused: isFocused),
                        lineWidth: boxBorderWidth(isFocused: isFocused)
                    )
                    .allowsHitTesting(false)
            }
    }

    private func boxBorderColor(isFocused: Bool) -> Color {
        if errorText != nil {
            return HermexTextInputColors.error
        }
        if colorSchemeContrast == .increased {
            return HermexSurfaceBorderColors.increasedContrast
        }
        return isFocused ? HermexSurfaceBorderColors.focused : HermexSurfaceBorderColors.resting
    }

    private func boxBorderWidth(isFocused: Bool) -> CGFloat {
        isFocused || errorText != nil || colorSchemeContrast == .increased ? 1.5 : 1
    }

    private var accessibilityValue: String {
        if code.isEmpty {
            return String(localized: "No digits entered. 0 of \(length).")
        }
        return String(localized: "\(code). \(code.count) of \(length) digits entered.")
    }

    private var accessibilityHint: Text {
        if let errorText {
            return errorText
        }
        if let helperText {
            return helperText
        }
        return Text("Enter a \(length)-digit code.")
    }

    private func normalizeBoundCode() {
        let normalized = HermexCodeInputNormalizer.normalize(code, length: length)
        if normalized != code {
            code = normalized
        }
    }
}
