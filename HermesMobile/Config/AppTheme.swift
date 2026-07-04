import Foundation
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            String(localized: "System")
        case .light:
            String(localized: "Light")
        case .dark:
            String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    static func storedValue(_ rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .system
    }
}

enum ZoraBrand {
    static let accessibilityLabel = String(localized: "Zora")

    // Samantha / Her-inspired core palette. Keep brand surfaces warm: coral,
    // vermillion, terracotta, ember, and cream — no cold greys or blue accents.
    static let ink = Color(red: 42.0 / 255.0, green: 11.0 / 255.0, blue: 3.0 / 255.0)
    static let coral = Color(red: 250.0 / 255.0, green: 113.0 / 255.0, blue: 61.0 / 255.0)
    static let vermillion = Color(red: 226.0 / 255.0, green: 74.0 / 255.0, blue: 37.0 / 255.0)
    static let terracotta = Color(red: 179.0 / 255.0, green: 60.0 / 255.0, blue: 30.0 / 255.0)
    static let ember = Color(red: 122.0 / 255.0, green: 36.0 / 255.0, blue: 16.0 / 255.0)
    static let paper = Color(red: 254.0 / 255.0, green: 240.0 / 255.0, blue: 219.0 / 255.0)

    static let foreground = paper
    static let secondaryForeground = paper.opacity(0.72)
    static let tertiaryForeground = paper.opacity(0.54)

    static let lightBackground = coral
    static let darkBackground = ember
    static let backgroundTop = coral
    static let backgroundMid = vermillion
    static let backgroundBottom = ember
    static let warmHighlight = paper
    static let selectionAccent = paper
    static let sessionPinActionTint = terracotta
    static let success = Color(red: 112.0 / 255.0, green: 214.0 / 255.0, blue: 142.0 / 255.0)
    static let warning = Color(red: 255.0 / 255.0, green: 194.0 / 255.0, blue: 107.0 / 255.0)
    static let danger = Color(red: 255.0 / 255.0, green: 112.0 / 255.0, blue: 88.0 / 255.0)

    static let veil = paper.opacity(0.72)
    static let whisper = paper.opacity(0.14)
    static let cardFill = paper.opacity(0.11)
    static let cardFillStrong = paper.opacity(0.16)
    static let cardStroke = whisper
    static let subtleFill = paper.opacity(0.06)
    static let hairline = whisper

    // Warm semantic surfaces for the Zora-branded app shell. These replace the
    // system greys/blacks that fight the terracotta canvas and mirror the wiki's
    // "calm surface + restrained hairline" treatment.
    static let surfaceHairline = paper.opacity(0.18)
    static let surfaceHairlineStrong = paper.opacity(0.30)
    static let listDivider = paper.opacity(0.16)
    static let listDividerStrong = paper.opacity(0.24)
    static let chatBubbleFill = Color(red: 140.0 / 255.0, green: 48.0 / 255.0, blue: 24.0 / 255.0).opacity(0.38)
    static let chatBubbleStroke = paper.opacity(0.22)
    static let inlineCodeFill = Color(red: 130.0 / 255.0, green: 44.0 / 255.0, blue: 22.0 / 255.0).opacity(0.32)
    static let codeBlockFill = Color(red: 120.0 / 255.0, green: 40.0 / 255.0, blue: 20.0 / 255.0).opacity(0.35)
    static let codeBlockStroke = paper.opacity(0.20)
    static let accessoryFill = paper.opacity(0.10)
    static let accessoryFillInset = paper.opacity(0.07)
    static let accessoryStroke = paper.opacity(0.20)
    static let accessoryAccent = paper.opacity(0.36)

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkBackground : lightBackground
    }
}

enum ZoraSpacing {
    static let unit: CGFloat = 8
    static let compact: CGFloat = 12
    static let screenInset: CGFloat = 24
    static let card: CGFloat = 16
    static let section: CGFloat = 24
    static let large: CGFloat = 32

    static let xs = unit
    static let sm = compact
    static let md = card
    static let lg = section
    static let xl = large
}

enum ZoraRadius {
    static let control: CGFloat = 999
    static let card: CGFloat = 22
    static let sheet: CGFloat = 28
    static let small: CGFloat = 8
}

enum ZoraMotion {
    static let standard = Animation.smooth(duration: 0.6)
    static let sheet = Animation.spring(response: 0.55, dampingFraction: 0.85)
    static let tap = Animation.spring(response: 0.3, dampingFraction: 0.7)
}

#if canImport(UIKit)
enum AppFormFactor: Equatable {
    case phone
    case tablet
    case desktop

    static func current(horizontalSizeClass: UserInterfaceSizeClass?) -> AppFormFactor {
        resolve(
            horizontalSizeClass: horizontalSizeClass,
            idiom: UIDevice.current.userInterfaceIdiom
        )
    }

    static func resolve(
        horizontalSizeClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom,
        isMacCatalyst: Bool = Self.isRunningMacCatalyst,
        isIOSAppOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
    ) -> AppFormFactor {
        if isMacCatalyst || isIOSAppOnMac || idiom == .mac {
            return .desktop
        }

        if idiom == .pad || (idiom == .unspecified && horizontalSizeClass == .regular) {
            return .tablet
        }

        return .phone
    }

    private static var isRunningMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

enum ZoraAdaptiveContentRole {
    case navigationList
    case readablePage
    case chatTranscript
    case floatingComposer

    func maxWidth(for formFactor: AppFormFactor) -> CGFloat? {
        switch (self, formFactor) {
        case (_, .phone):
            return nil
        case (.navigationList, .tablet):
            return 560
        case (.navigationList, .desktop):
            return 600
        case (.readablePage, .tablet):
            return 760
        case (.readablePage, .desktop):
            return 820
        case (.chatTranscript, .tablet):
            return 860
        case (.chatTranscript, .desktop):
            return 940
        case (.floatingComposer, .tablet):
            return 760
        case (.floatingComposer, .desktop):
            return 860
        }
    }

    func outerAlignment(for formFactor: AppFormFactor) -> Alignment {
        formFactor == .phone ? .topLeading : .top
    }
}

private struct ZoraAdaptiveContentFrameModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let role: ZoraAdaptiveContentRole

    func body(content: Content) -> some View {
        let formFactor = AppFormFactor.current(horizontalSizeClass: horizontalSizeClass)

        content
            .frame(maxWidth: role.maxWidth(for: formFactor), alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: role.outerAlignment(for: formFactor))
    }
}
#endif

enum ZoraSurfaceLevel {
    case subtle
    case card
    case strong
    case chrome

    func fill(reduceTransparency: Bool) -> Color {
        switch self {
        case .subtle:
            return reduceTransparency ? ZoraBrand.backgroundMid.opacity(0.82) : ZoraBrand.subtleFill
        case .card:
            return reduceTransparency ? ZoraBrand.backgroundMid.opacity(0.92) : ZoraBrand.cardFill
        case .strong:
            return reduceTransparency ? ZoraBrand.backgroundMid.opacity(0.96) : ZoraBrand.cardFillStrong
        case .chrome:
            return reduceTransparency ? ZoraBrand.backgroundBottom.opacity(0.90) : ZoraBrand.paper.opacity(0.075)
        }
    }

    var stroke: Color {
        switch self {
        case .subtle, .chrome:
            return ZoraBrand.hairline
        case .card:
            return ZoraBrand.cardStroke
        case .strong:
            return ZoraBrand.foreground.opacity(0.22)
        }
    }
}

struct ZoraPrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = ZoraRadius.small

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(ZoraBrand.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(ZoraBrand.foreground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: ZoraBrand.foreground.opacity(configuration.isPressed ? 0.08 : 0.18), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(ZoraMotion.tap, value: configuration.isPressed)
    }
}

struct ZoraSecondaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = ZoraRadius.small

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(ZoraBrand.secondaryForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(ZoraSurfaceLevel.subtle.fill(reduceTransparency: false), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ZoraBrand.hairline, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(ZoraMotion.tap, value: configuration.isPressed)
    }
}

private struct ZoraSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let level: ZoraSurfaceLevel
    let cornerRadius: CGFloat
    let showsShadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(shape.fill(level.fill(reduceTransparency: reduceTransparency)))
            .overlay(
                shape
                    .stroke(
                        colorSchemeContrast == .increased ? ZoraBrand.foreground.opacity(0.42) : level.stroke,
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: showsShadow ? Color.black.opacity(reduceTransparency ? 0.14 : 0.20) : .clear, radius: showsShadow ? 16 : 0, y: showsShadow ? 8 : 0)
    }
}

struct ZoraBrandBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(
                stops: [
                    .init(color: ZoraBrand.coral, location: 0),
                    .init(color: ZoraBrand.vermillion, location: 0.42),
                    .init(color: ZoraBrand.terracotta, location: 0.72),
                    .init(color: ZoraBrand.ember, location: 1)
                ],
                center: .top,
                startRadius: 40,
                endRadius: 920
            )

            RadialGradient(
                colors: [ZoraBrand.paper.opacity(0.20), .clear],
                center: .topTrailing,
                startRadius: 16,
                endRadius: 460
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [ZoraBrand.ember.opacity(0.52), .clear],
                center: .bottom,
                startRadius: 20,
                endRadius: 560
            )
            .blendMode(.multiply)
        }
    }
}

struct ZoraHeaderWordmark: View {
    let selectedColor: Color
    let isBrandLocked: Bool

    init(selectedColor: Color = ZoraBrand.foreground, isBrandLocked: Bool = true) {
        self.selectedColor = selectedColor
        self.isBrandLocked = isBrandLocked
    }

    var body: some View {
        let foreground = isBrandLocked ? ZoraBrand.foreground : selectedColor

        HStack(spacing: 11) {
            ZoraWaveformMark(color: foreground)
                .frame(width: 54, height: 28)

            Text("Zora")
                .font(.system(size: 31, weight: .regular, design: .serif))
                .italic()
                .tracking(-0.62)
                .foregroundStyle(foreground)
                .minimumScaleFactor(0.82)
        }
        .frame(width: 156, height: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ZoraBrand.accessibilityLabel)
    }
}

enum ZoraWaveState: Equatable {
    case idle
    case listening
    case speaking(intensity: Double)
    case thinking

    var amplitude: Double {
        switch self {
        case .idle:
            return 0.16
        case .listening:
            return 0.35
        case let .speaking(intensity):
            return 0.45 + (0.45 * max(0, min(1, intensity)))
        case .thinking:
            return 0.22
        }
    }

    var speed: Double {
        switch self {
        case .idle:
            return 0.52
        case .listening:
            return 0.9
        case .speaking:
            return 1.6
        case .thinking:
            return 1.1
        }
    }

    var harmonics: Int {
        switch self {
        case .idle:
            return 3
        case .listening, .thinking:
            return 3
        case .speaking:
            return 4
        }
    }

    var envelope: ZoraWaveShape.Envelope {
        switch self {
        case .idle:
            return .traveling
        case .thinking:
            return .traveling
        default:
            return .centered
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:
            return String(localized: "Zora is idle")
        case .listening:
            return String(localized: "Zora is listening")
        case .speaking:
            return String(localized: "Zora is speaking")
        case .thinking:
            return String(localized: "Zora is thinking")
        }
    }
}

struct ZoraWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var state: ZoraWaveState = .idle
    var tint: Color = ZoraBrand.foreground
    var lineWidth: CGFloat = 3
    var glow = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let renderedState: ZoraWaveState = reduceMotion ? .idle : state
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * renderedState.speed

            ZoraWaveShape(
                phase: phase,
                amplitude: renderedState.amplitude,
                harmonics: renderedState.harmonics,
                envelope: renderedState.envelope
            )
            .stroke(
                tint,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: glow ? tint.opacity(0.55) : .clear, radius: glow ? 8 : 0)
            .shadow(color: glow ? tint.opacity(0.30) : .clear, radius: glow ? 18 : 0)
            .animation(ZoraMotion.standard, value: renderedState)
            .drawingGroup()
        }
        .accessibilityLabel(state.accessibilityLabel)
    }
}

struct ZoraWaveShape: Shape {
    enum Envelope {
        case centered
        case traveling
        case uniform
    }

    var phase: Double
    var amplitude: Double
    var harmonics: Int
    var envelope: Envelope

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, amplitude) }
        set {
            phase = newValue.first
            amplitude = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let maxAmp = rect.height * 0.5 * 0.9
        let sampleCount = max(64, Int(rect.width / 2))

        for index in 0...sampleCount {
            let progress = Double(index) / Double(sampleCount)
            let x = rect.minX + CGFloat(progress) * rect.width
            let envelopeValue: Double

            switch envelope {
            case .centered:
                envelopeValue = pow(sin(.pi * progress), 2)
            case .traveling:
                let center = (phase * 0.15).truncatingRemainder(dividingBy: 1.0)
                let distance = min(abs(progress - center), 1 - abs(progress - center))
                let windowWidth = 0.28
                envelopeValue = distance < windowWidth ? pow(cos(.pi * distance / (2 * windowWidth)), 2) : 0
            case .uniform:
                envelopeValue = 1
            }

            var y: Double = 0
            for harmonic in 1...harmonics {
                let frequency = Double(harmonic) * 2.2
                let phaseOffset = phase * (0.7 + (0.35 * Double(harmonic)))
                let weight = 1.0 / Double(harmonic)
                y += weight * sin((2 * .pi * frequency * progress) + phaseOffset)
            }

            y *= 1.0 / (1.0 + log(Double(harmonics)))

            let displacement = y * envelopeValue * amplitude * Double(maxAmp)
            let point = CGPoint(x: x, y: midY + CGFloat(displacement))

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}

private struct ZoraWaveformMark: View {
    let color: Color

    var body: some View {
        ZoraWaveform(state: .idle, tint: color, lineWidth: 2.4, glow: true)
            .accessibilityHidden(true)
    }
}

private struct ZoraBrandedScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ZoraBrandBackground().ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(ZoraBrand.foreground)
    }
}

extension View {
    func zoraBrandedScreen() -> some View {
        modifier(ZoraBrandedScreenModifier())
    }

    #if canImport(UIKit)
    func zoraAdaptiveContentFrame(_ role: ZoraAdaptiveContentRole) -> some View {
        modifier(ZoraAdaptiveContentFrameModifier(role: role))
    }
    #endif

    func zoraSurface(
        _ level: ZoraSurfaceLevel = .card,
        cornerRadius: CGFloat = ZoraRadius.card,
        showsShadow: Bool = false
    ) -> some View {
        modifier(
            ZoraSurfaceModifier(
                level: level,
                cornerRadius: cornerRadius,
                showsShadow: showsShadow
            )
        )
    }
}

struct HeaderLogoColorPreset: Identifiable, Equatable {
    let name: String
    let hex: String

    var id: String { hex }

    var color: Color {
        HeaderLogoColor.color(for: hex)
    }
}

enum HeaderLogoColor {
    static let storageKey = "headerLogoColorHex"
    static let defaultHex = "#FEF0DB"

    static let presets: [HeaderLogoColorPreset] = [
        HeaderLogoColorPreset(name: String(localized: "Cream"), hex: "#FEF0DB"),
        HeaderLogoColorPreset(name: String(localized: "Coral"), hex: "#FA713D"),
        HeaderLogoColorPreset(name: String(localized: "Vermillion"), hex: "#E24A25"),
        HeaderLogoColorPreset(name: String(localized: "Terracotta"), hex: "#B33C1E"),
        HeaderLogoColorPreset(name: String(localized: "Ember"), hex: "#7A2410")
    ]

    static func normalizedHex(_ rawValue: String) -> String? {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        return "#\(hex.uppercased())"
    }

    static func color(for rawValue: String) -> Color {
        Color(hexRGB: normalizedHex(rawValue) ?? defaultHex) ?? ZoraBrand.foreground
    }

    static func prefersDarkForeground(for rawValue: String) -> Bool {
        guard let components = rgbComponents(for: rawValue) else {
            return true
        }

        let luminance = (0.2126 * components.red) + (0.7152 * components.green) + (0.0722 * components.blue)
        return luminance > 0.50
    }

    static func displayName(for rawValue: String) -> String {
        let hex = normalizedHex(rawValue) ?? defaultHex
        return presets.first { $0.hex == hex }?.name ?? String(localized: "Custom")
    }

    static func hexString(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        String(
            format: "#%02X%02X%02X",
            clampedByte(red),
            clampedByte(green),
            clampedByte(blue)
        )
    }

    static func hexString(from color: Color) -> String? {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return hexString(red: red, green: green, blue: blue)
        #else
        return nil
        #endif
    }

    private static func clampedByte(_ component: CGFloat) -> Int {
        min(255, max(0, Int(round(component * 255))))
    }

    private static func rgbComponents(for rawValue: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalizedHex(rawValue),
              let value = UInt32(String(hex.dropFirst()), radix: 16)
        else {
            return rgbComponents(for: defaultHex)
        }

        return (
            Double((value & 0xFF0000) >> 16) / 255.0,
            Double((value & 0x00FF00) >> 8) / 255.0,
            Double(value & 0x0000FF) / 255.0
        )
    }
}

extension Color {
    init?(hexRGB rawValue: String) {
        guard let hex = HeaderLogoColor.normalizedHex(rawValue),
              let value = UInt32(String(hex.dropFirst()), radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }
}

/// User-facing switch (issue #261) for tinting the primary actions — the
/// "New Chat" button and the composer "Send" button — with the chosen Header
/// Logo Color instead of the default monochrome fill. Defaults to off (opt-in);
/// a control keeps its muted/monochrome look while disabled so a tinted-but-dead
/// button never reads as interactive.
enum PrimaryActionTintSettings {
    static let isEnabledKey = "appearance.tintsPrimaryActionsWithThemeColor"

    /// A primary action adopts the theme color only when the user enabled the
    /// setting *and* the control is currently interactive.
    static func usesThemeColor(isEnabled: Bool, controlIsEnabled: Bool) -> Bool {
        isEnabled && controlIsEnabled
    }
}

enum AppHaptics {
    static let isEnabledKey = "appHaptics.isEnabled"
}

enum ResponseCompletionNotifications {
    static let isEnabledKey = "responseCompletionNotifications.isEnabled"
    static let hasRequestedPermissionKey = "responseCompletionNotifications.hasRequestedPermission"
}

enum AgentRunLiveActivityPrivacy {
    static let showsResponseExcerptsKey = "agentRunLiveActivity.showsResponseExcerpts"
}

/// User-facing switch for the streamed-text fade-in (issues #213/#234).
/// Defaults to on; Reduce Motion disables the animation regardless.
enum StreamedTextAnimationSettings {
    static let isEnabledKey = "chatTranscript.streamedTextAnimationEnabled"

    /// The fade-window start ordinal the renderer should use. `Int.max`
    /// routes every block into the solid head, so no fade renderer (and no
    /// frame clock) is ever attached — disabling the animation entirely.
    static func effectiveFirstFadeOrdinal(
        _ firstFadeOrdinal: Int,
        reduceMotion: Bool,
        isEnabled: Bool
    ) -> Int {
        (reduceMotion || !isEnabled) ? Int.max : firstFadeOrdinal
    }
}

enum ChatTranscriptDisplaySettings {
    static let showsThinkingAndToolCardsKey = "chatTranscript.showsThinkingAndToolCards"
    static let thinkingCardsStartExpandedKey = "chatTranscript.thinkingCardsStartExpanded"
    static let toolCardsStartExpandedKey = "chatTranscript.toolCardsStartExpanded"
    static let hidesAttachmentPathsKey = "chatTranscript.hidesAttachmentPaths"
    static let showsAssistantTurnTimestampsKey = "chatTranscript.showsAssistantTurnTimestamps"
    static let wrapsCodeBlockLinesKey = "chatTranscript.wrapsCodeBlockLines"

    /// Backs the Settings → Chat "Right-to-Left Chat Layout" toggle (issue #259).
    /// Local-only: there is no server settings object to mirror an `rtl` flag
    /// through today, so the reporter's optional `settings.rtl` server sync is
    /// deferred rather than guessed at (project hard rule: never invent API shapes).
    static let rtlChatLayoutEnabledKey = "chatTranscript.rtlChatLayoutEnabled"

    /// The chat-canvas layout direction for a given toggle state. The toggle is a
    /// manual override that persists once tapped; its *default* follows the
    /// device language (see `rtlChatLayoutDefaultEnabled`).
    static func chatLayoutDirection(rtlEnabled: Bool) -> LayoutDirection {
        rtlEnabled ? .rightToLeft : .leftToRight
    }

    /// Whether the user's primary preferred language reads right-to-left
    /// (Arabic/Hebrew/Persian/Urdu/…). Read from the device language *preference*
    /// — not the app's resolved UI direction — so it still fires for an RTL user
    /// even though Hermex isn't translated into their language yet: the app text
    /// falls back to English (LTR), but the chat layout should not. Only the
    /// primary preference counts (a German-first user with Arabic further down
    /// the list is "using German"). `preferredLanguages` is injectable for tests.
    static func isRightToLeftLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        guard let primary = preferredLanguages.first else { return false }
        return Locale.Language(identifier: primary).characterDirection == .rightToLeft
    }

    /// Default state of the RTL chat toggle: on for RTL-language users so the chat
    /// mirrors automatically, off otherwise. Used as the `@AppStorage` default, so
    /// a user's explicit toggle still overrides it and persists (#259).
    static var rtlChatLayoutDefaultEnabled: Bool {
        isRightToLeftLanguage()
    }

    /// A card's expansion follows the start-expanded preference until the user
    /// taps it; the per-card tap override then wins for the rest of the session.
    static func isCardExpanded(userToggled: Bool?, startsExpanded: Bool) -> Bool {
        userToggled ?? startsExpanded
    }

    static func shouldShowAssistantTypingIndicator(
        hasActiveStream: Bool,
        isCancellingStream: Bool,
        hasStreamingAssistantMessage: Bool,
        hasPendingClarificationPrompt: Bool = false,
        liveReasoningText: String,
        hasLiveToolCalls: Bool,
        showsThinkingAndToolCards: Bool
    ) -> Bool {
        guard hasActiveStream, !isCancellingStream else { return false }
        guard !hasStreamingAssistantMessage else { return false }
        guard !hasPendingClarificationPrompt else { return false }

        guard showsThinkingAndToolCards else {
            return true
        }

        guard liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !hasLiveToolCalls
    }

    static func shouldUseStreamingBubbleRendering(
        hasActiveStream: Bool,
        messageRole: String?,
        messageID: String?,
        streamingAssistantMessageID: String?
    ) -> Bool {
        hasActiveStream &&
            messageRole == "assistant" &&
            streamingAssistantMessageID != nil &&
            messageID == streamingAssistantMessageID
    }

    /// Whether to draw the per-turn `glyph + timestamp` header above an assistant
    /// turn. The header is a turn *separator*, not an identity, so it is limited
    /// to real assistant turns that carry visible text — never user bubbles,
    /// system/marker cards, tool-call cards, or empty/tool-only assistant rows.
    static func showsAssistantTurnHeader(
        role: String?,
        hasTextContent: Bool,
        isEnabled: Bool
    ) -> Bool {
        isEnabled && role == "assistant" && hasTextContent
    }
}

/// Pure helpers for the few *physical* layout values SwiftUI does not mirror on
/// its own under right-to-left layout (issue #294 — app-wide RTL). Semantic edges
/// (`.leading`/`.trailing`) and toolbar placements flip automatically; these cover
/// the exceptions: a manual `.offset(x:)` and a rotating disclosure chevron.
enum RTLLayout {
    /// Mirror a physical horizontal offset so a corner-anchored overlay stays on
    /// the same visual side as its `.topTrailing`/`.topLeading` anchor: a positive
    /// (rightward) offset becomes leftward under RTL.
    static func horizontalOffset(_ x: CGFloat, isRightToLeft: Bool) -> CGFloat {
        isRightToLeft ? -x : x
    }

    /// Expand-rotation (degrees) for a disclosure chevron drawn with a mirroring
    /// base glyph (`chevron.forward`): collapsed, the glyph already points toward
    /// the reveal direction, so the rotation must reverse under RTL for the
    /// expanded state to still point *down* rather than up.
    static func disclosureChevronRotationDegrees(isExpanded: Bool, isRightToLeft: Bool) -> Double {
        guard isExpanded else { return 0 }
        return isRightToLeft ? -90 : 90
    }
}

enum ChatActiveRunStatusKind: Equatable {
    case starting
    case active
    case checking
    case reconnecting
    case stopping

    var label: String {
        switch self {
        case .starting:
            return String(localized: "Starting response")
        case .active:
            return String(localized: "Hermes is working")
        case .checking:
            return String(localized: "Checking stream")
        case .reconnecting:
            return String(localized: "Reconnecting stream")
        case .stopping:
            return String(localized: "Stopping response")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .starting:
            return String(localized: "Hermes is starting a response")
        case .active:
            return String(localized: "Hermes is working on the response")
        case .checking:
            return String(localized: "Hermes is checking the response stream")
        case .reconnecting:
            return String(localized: "Hermes is reconnecting the response stream")
        case .stopping:
            return String(localized: "Hermes is stopping the response")
        }
    }
}

struct ChatActiveRunStatusPresentation: Equatable {
    let kind: ChatActiveRunStatusKind

    var label: String {
        kind.label
    }

    var accessibilityLabel: String {
        kind.accessibilityLabel
    }
}

enum ChatActiveRunStatusPolicy {
    static func presentation(
        isStartingChat: Bool,
        hasActiveStream: Bool,
        activeStreamRecoveryState: ActiveStreamRecoveryState,
        isCancellingStream: Bool,
        isScrolledNearBottom: Bool
    ) -> ChatActiveRunStatusPresentation? {
        guard !isScrolledNearBottom else { return nil }

        if isCancellingStream {
            return ChatActiveRunStatusPresentation(kind: .stopping)
        }

        if isStartingChat {
            return ChatActiveRunStatusPresentation(kind: .starting)
        }

        switch activeStreamRecoveryState {
        case .checking:
            return ChatActiveRunStatusPresentation(kind: .checking)
        case .reconnecting:
            return ChatActiveRunStatusPresentation(kind: .reconnecting)
        case .idle:
            break
        }

        guard hasActiveStream else { return nil }
        return ChatActiveRunStatusPresentation(kind: .active)
    }
}

enum ResponseCompletionNotificationPolicy {
    /// Fire a "response complete" notification when the user almost certainly isn't
    /// watching: notifications are enabled + permitted, the run finished normally,
    /// and the scene is not active at completion time. Deliberately does NOT depend
    /// on any "was streaming" / "was backgrounded during the stream" memory — those
    /// in-memory flags were wiped on suspend→cold-relaunch, which is exactly when the
    /// stuck-mid-response reports happened (#248). Every in-session completion path
    /// funnels through one chokepoint, so scene-not-active is the only gate needed.
    static func shouldSchedule(
        preferenceEnabled: Bool,
        authorizationStatus: UNAuthorizationStatus,
        completedNormally: Bool,
        sceneIsActive: Bool
    ) -> Bool {
        guard preferenceEnabled,
              authorizationStatus.allowsResponseCompletionNotifications,
              completedNormally,
              !sceneIsActive else {
            return false
        }

        return true
    }
}

struct ResponseCompletionNotificationRequest: Equatable {
    static let title = String(localized: "Hermes response complete")
    static let body = String(localized: "The assistant finished responding.")

    let sessionID: String?

    var userInfo: [String: String] {
        guard let sessionID, !sessionID.isEmpty else { return [:] }
        return ["session_id": sessionID]
    }
}

struct ResponseCompletionNotificationCompletionContext: Equatable {
    let sceneIsActive: Bool
}

struct ResponseCompletionNotificationTracker {
    private var lastHandledCompletionTrigger = 0

    func shouldEndBackgroundTaskOnStreamInactive(completionTrigger: Int) -> Bool {
        completionTrigger <= lastHandledCompletionTrigger
    }

    /// Returns the completion context exactly once per completion trigger, so a run
    /// that completes is handled a single time even if the trigger is observed
    /// repeatedly. The scene state at completion is the only gate the policy needs.
    mutating func completionContext(
        completionTrigger: Int,
        sceneIsActive: Bool
    ) -> ResponseCompletionNotificationCompletionContext? {
        guard completionTrigger > lastHandledCompletionTrigger else {
            return nil
        }

        lastHandledCompletionTrigger = completionTrigger
        return ResponseCompletionNotificationCompletionContext(sceneIsActive: sceneIsActive)
    }
}

protocol ResponseCompletionNotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func schedule(_ request: ResponseCompletionNotificationRequest) async
}

struct UserNotificationResponseCompletionScheduler: ResponseCompletionNotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func schedule(_ request: ResponseCompletionNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = ResponseCompletionNotificationRequest.title
        content.body = ResponseCompletionNotificationRequest.body
        content.sound = .default
        content.userInfo = request.userInfo

        let identifierSessionPart: String
        if let sessionID = request.sessionID, !sessionID.isEmpty {
            identifierSessionPart = sessionID
        } else {
            identifierSessionPart = UUID().uuidString
        }
        let notificationRequest = UNNotificationRequest(
            identifier: "response-complete-\(identifierSessionPart)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(notificationRequest) { _ in
                continuation.resume()
            }
        }
    }
}

enum ResponseCompletionNotificationService {
    static func authorizationStatus(
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> UNAuthorizationStatus {
        await scheduler.authorizationStatus()
    }

    static func requestAuthorization(
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> Bool {
        await scheduler.requestAuthorization()
    }

    @discardableResult
    static func scheduleResponseCompletedIfAllowed(
        sessionID: String?,
        preferenceEnabled: Bool,
        completedNormally: Bool,
        sceneIsActive: Bool,
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> Bool {
        let status = await authorizationStatus(scheduler: scheduler)
        guard ResponseCompletionNotificationPolicy.shouldSchedule(
            preferenceEnabled: preferenceEnabled,
            authorizationStatus: status,
            completedNormally: completedNormally,
            sceneIsActive: sceneIsActive
        ) else {
            return false
        }

        await scheduler.schedule(ResponseCompletionNotificationRequest(sessionID: sessionID))
        return true
    }
}

private extension UNAuthorizationStatus {
    var allowsResponseCompletionNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

enum StreamingSendBehavior: String, CaseIterable, Identifiable {
    case steer
    case interrupt
    case queue

    static let storageKey = "streamingSendBehavior"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer:
            "Steer"
        case .interrupt:
            "Interrupt"
        case .queue:
            "Queue"
        }
    }

    var settingsDescription: String {
        switch self {
        case .steer:
            String(localized: "Steer active response")
        case .interrupt:
            String(localized: "Stop and send")
        case .queue:
            String(localized: "Send after response")
        }
    }

    static func storedValue(_ rawValue: String) -> StreamingSendBehavior {
        StreamingSendBehavior(rawValue: rawValue) ?? .steer
    }
}
