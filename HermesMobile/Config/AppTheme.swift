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
    static let defaultHex = "#FFD700"

    static let presets: [HeaderLogoColorPreset] = [
        HeaderLogoColorPreset(name: String(localized: "Yellow"), hex: "#FFD700"),
        HeaderLogoColorPreset(name: String(localized: "Blue"), hex: "#5B7CFF"),
        HeaderLogoColorPreset(name: String(localized: "Purple"), hex: "#AF52DE"),
        HeaderLogoColorPreset(name: String(localized: "Red"), hex: "#FF3B30"),
        HeaderLogoColorPreset(name: String(localized: "Green"), hex: "#34C759"),
        HeaderLogoColorPreset(name: String(localized: "White"), hex: "#FFFFFF")
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
        Color(hexRGB: normalizedHex(rawValue) ?? defaultHex) ?? Color(red: 1.0, green: 0.843, blue: 0.0)
    }

    static func prefersDarkForeground(for rawValue: String) -> Bool {
        guard let components = rgbComponents(for: rawValue) else {
            return true
        }

        let luminance = (0.2126 * components.red) + (0.7152 * components.green) + (0.0722 * components.blue)
        return luminance > 0.62
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

enum ComposerSTTProviderPreference: String, CaseIterable, Identifiable {
    case serverFirst
    case onDeviceFirst
    case onDeviceOnly

    static let storageKey = "composerSTTProviderPreference"
    static let defaultValue: ComposerSTTProviderPreference = .serverFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serverFirst:
            String(localized: "Server first")
        case .onDeviceFirst:
            String(localized: "On-device first")
        case .onDeviceOnly:
            String(localized: "On-device only")
        }
    }

    static func storedValue(_ rawValue: String) -> ComposerSTTProviderPreference {
        ComposerSTTProviderPreference(rawValue: rawValue) ?? defaultValue
    }
}

enum ComposerSTTProvider: Equatable {
    case server
    case onDevice
}

enum ComposerSTTProviderPolicy {
    static func orderedProviders(
        preference: ComposerSTTProviderPreference,
        serverConfigured: Bool,
        onDeviceSupported: Bool
    ) -> [ComposerSTTProvider] {
        switch preference {
        case .serverFirst:
            return compactProviders(
                (.server, serverConfigured),
                (.onDevice, onDeviceSupported)
            )
        case .onDeviceFirst:
            return compactProviders(
                (.onDevice, onDeviceSupported),
                (.server, serverConfigured)
            )
        case .onDeviceOnly:
            return compactProviders((.onDevice, onDeviceSupported))
        }
    }

    static func fallbackProvider(
        after failedProvider: ComposerSTTProvider,
        preference: ComposerSTTProviderPreference,
        serverConfigured: Bool,
        onDeviceSupported: Bool
    ) -> ComposerSTTProvider? {
        let providers = orderedProviders(
            preference: preference,
            serverConfigured: serverConfigured,
            onDeviceSupported: onDeviceSupported
        )
        guard let failedIndex = providers.firstIndex(of: failedProvider) else {
            return nil
        }

        let fallbackIndex = providers.index(after: failedIndex)
        guard fallbackIndex < providers.endIndex else {
            return nil
        }
        return providers[fallbackIndex]
    }

    private static func compactProviders(
        _ candidates: (ComposerSTTProvider, Bool)...
    ) -> [ComposerSTTProvider] {
        candidates.compactMap { provider, isAvailable in
            isAvailable ? provider : nil
        }
    }
}
