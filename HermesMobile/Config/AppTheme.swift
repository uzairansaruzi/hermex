import CryptoKit
import Foundation
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

enum TipJar {
    static let dismissedReleaseKey = "tipJar.dismissedRelease"
    static let linkOpenedKey = "tipJar.linkOpened"
    static let completedResponseCountKey = "engagement.completedResponseCount"
}

enum GitHubStar {
    static let dismissedReleaseKey = "githubStar.dismissedRelease"
    static let linkOpenedKey = "githubStar.linkOpened"
}

enum RatingPromptSettings {
    static let firstLaunchDateKey = "ratingPrompt.firstLaunchDate"
    static let lastRequestDateKey = "ratingPrompt.lastRequestDate"
    static let responseCountAtLastRequestKey = "ratingPrompt.responseCountAtLastRequest"
}

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

enum AppTextSize {
    static let storageKey = "appearance.textSizeStop"

    static let stops: [DynamicTypeSize?] = [
        nil,
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    static func size(atStop stop: Int) -> DynamicTypeSize? {
        stops.indices.contains(stop) ? stops[stop] : nil
    }

    static func percentage(of size: DynamicTypeSize) -> Double {
        let standard = UIFont.preferredFont(forTextStyle: .body, at: .large).pointSize
        return UIFont.preferredFont(forTextStyle: .body, at: size).pointSize / standard
    }

    @MainActor static func applyStoredSize(to scene: UIWindowScene) {
        let size = self.size(atStop: UserDefaults.standard.integer(forKey: storageKey))
        if let size {
            scene.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(size)
        } else {
            scene.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
    }

    @MainActor static func applyStoredSizeToConnectedScenes() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            applyStoredSize(to: scene)
        }
    }
}

extension UIFont {
    static func preferredFont(forTextStyle style: TextStyle, at size: DynamicTypeSize) -> UIFont {
        preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        )
    }
}

enum CodeDisplaySettings {
    static let wrapsLinesKey = "chatTranscript.wrapsCodeBlockLines"
    private static let legacySourceWrapsLinesKey = "workspace.sourceViewer.wrapsLines"

    static let customSizeKey = "appearance.customCodeSize"
    static let customSizeRange: ClosedRange<Double> = 10...28

    static func migrateWrapSetting(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacySourceWrapsLinesKey) != nil else { return }
        if defaults.bool(forKey: legacySourceWrapsLinesKey) {
            defaults.set(true, forKey: wrapsLinesKey)
        }
        defaults.removeObject(forKey: legacySourceWrapsLinesKey)
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

enum PrimaryActionTintSettings {
    static let isEnabledKey = "appearance.tintsPrimaryActionsWithThemeColor"

    static func usesThemeColor(isEnabled: Bool, controlIsEnabled: Bool) -> Bool {
        isEnabled && controlIsEnabled
    }

    static func colors(accentHex: String?, serverHex: String) -> (fill: Color, label: Color) {
        if accentHex.flatMap(HeaderLogoColor.normalizedHex) != nil {
            return (Color(.appAccent), Color(.appOnAccent))
        }
        return (
            HeaderLogoColor.color(for: serverHex),
            HeaderLogoColor.prefersDarkForeground(for: serverHex) ? .black : .white
        )
    }
}

enum AppHaptics {
    static let isEnabledKey = "appHaptics.isEnabled"
    static let streamingPulseIsEnabledKey = "appHaptics.streamingPulse.isEnabled"
}

enum ResponseCompletionNotifications {
    static let isEnabledKey = "responseCompletionNotifications.isEnabled"
    static let hasRequestedPermissionKey = "responseCompletionNotifications.hasRequestedPermission"
}

enum AgentRunLiveActivityPrivacy {
    static let showsResponseExcerptsKey = "agentRunLiveActivity.showsResponseExcerpts"
}

enum ThinkingAndToolCards: String, CaseIterable, Identifiable {
    case hidden
    case collapsed
    case expanded

    var id: Self { self }

    var title: String {
        switch self {
        case .hidden: String(localized: "Hidden")
        case .collapsed: String(localized: "Collapsed")
        case .expanded: String(localized: "Expanded")
        }
    }

    var showsCards: Bool { self != .hidden }
    var startsExpanded: Bool { self == .expanded }
}

enum ChatTranscriptDisplaySettings {
    static let thinkingAndToolCardsKey = "chatTranscript.thinkingAndToolCards"

    private static let legacyShowsCardsKey = "chatTranscript.showsThinkingAndToolCards"
    private static let legacyThinkingExpandedKey = "chatTranscript.thinkingCardsStartExpanded"
    private static let legacyToolsExpandedKey = "chatTranscript.toolCardsStartExpanded"

    static func migrateThinkingAndToolCards(in defaults: UserDefaults = .standard) {
        let legacyKeys = [legacyShowsCardsKey, legacyThinkingExpandedKey, legacyToolsExpandedKey]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        if defaults.object(forKey: thinkingAndToolCardsKey) == nil {
            let mode: ThinkingAndToolCards
            if defaults.object(forKey: legacyShowsCardsKey) as? Bool == false {
                mode = .hidden
            } else if defaults.bool(forKey: legacyThinkingExpandedKey) || defaults.bool(forKey: legacyToolsExpandedKey) {
                mode = .expanded
            } else {
                mode = .collapsed
            }
            defaults.set(mode.rawValue, forKey: thinkingAndToolCardsKey)
        }
        legacyKeys.forEach(defaults.removeObject(forKey:))
    }

    static let hidesAttachmentPathsKey = "chatTranscript.hidesAttachmentPaths"
    static let showsAssistantTurnTimestampsKey = "chatTranscript.showsAssistantTurnTimestamps"
    static let defaultShowsTimestamps = true
    static let showsResponseSpeedKey = "chatTranscript.showsResponseSpeed"
    static let showsServerLinkBannerKey = "chatTranscript.showsServerLinkBanner"
    static let defaultShowsServerLinkBanner = false
    static let foldsSettledTurnsKey = "chatTranscript.foldsSettledTurns"

    static let rtlChatLayoutEnabledKey = "chatTranscript.rtlChatLayoutEnabled"

    static func chatLayoutDirection(rtlEnabled: Bool) -> LayoutDirection {
        rtlEnabled ? .rightToLeft : .leftToRight
    }

    static func isRightToLeftLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        guard let primary = preferredLanguages.first else { return false }
        return Locale.Language(identifier: primary).characterDirection == .rightToLeft
    }

    static var rtlChatLayoutDefaultEnabled: Bool {
        isRightToLeftLanguage()
    }

    static func isCardExpanded(userToggled: Bool?, startsExpanded: Bool) -> Bool {
        userToggled ?? startsExpanded
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

    static func showsAssistantTurnHeader(
        role: String?,
        hasTextContent: Bool,
        showsResponseSpeed: Bool,
        hasResponseSpeed: Bool
    ) -> Bool {
        showsResponseSpeed &&
            hasResponseSpeed &&
            role == "assistant" &&
            hasTextContent
    }
}

enum SectionVisibilitySettings {
    static let tasksKey = "sectionVisibility.tasks"
    static let kanbanKey = "sectionVisibility.kanban"
    static let skillsKey = "sectionVisibility.skills"
    static let memoryKey = "sectionVisibility.memory"
    static let insightsKey = "sectionVisibility.insights"
    static let activeProfileKey = "sectionVisibility.activeProfile"
    static let projectsKey = "sectionVisibility.projects"
    static let chatFilesKey = "sectionVisibility.chatFiles"
    static let chatGitKey = "sectionVisibility.chatGit"
}

enum BotModeGate {
    static let isEnabledKey = "botMode.isEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: isEnabledKey)
    }
}

enum RTLLayout {
    static func horizontalOffset(_ x: CGFloat, isRightToLeft: Bool) -> CGFloat {
        isRightToLeft ? -x : x
    }

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
    case waitingForNetwork
    case stopping
    case waitingForUser

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
        case .waitingForNetwork:
            return String(localized: "Waiting for network")
        case .stopping:
            return String(localized: "Stopping response")
        case .waitingForUser:
            return String(localized: "Waiting for you")
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
        case .waitingForNetwork:
            return String(localized: "Hermes is waiting for the network to return")
        case .stopping:
            return String(localized: "Hermes is stopping the response")
        case .waitingForUser:
            return String(localized: "Waiting for your answer")
        }
    }
}

struct ChatActiveRunStatusPresentation: Equatable {
    let kind: ChatActiveRunStatusKind
    let startedAt: Date?
    let isCompacting: Bool

    init(kind: ChatActiveRunStatusKind, startedAt: Date? = nil, isCompacting: Bool = false) {
        self.kind = kind
        self.startedAt = kind == .active ? startedAt : nil
        self.isCompacting = kind == .active && isCompacting
    }

    func label(now: Date) -> String {
        guard let startedAt else { return kind.label }
        if isCompacting { return ChatWorkingRowLabel.text(startedAt: startedAt, now: now, isCompacting: true) }
        return String(
            localized: "Hermes is working · \(ChatWorkingElapsedFormatter.label(startedAt: startedAt, now: now))"
        )
    }

    func accessibilityLabel(now: Date) -> String {
        guard let startedAt else { return kind.accessibilityLabel }
        if isCompacting {
            return ChatWorkingRowLabel.accessibilityLabel(startedAt: startedAt, now: now, isCompacting: true)
        }
        return String(
            localized: "Hermes has been working for \(ChatWorkingElapsedFormatter.spokenLabel(startedAt: startedAt, now: now))"
        )
    }
}

enum ChatActiveRunStatusPolicy {
    static func presentation(
        isStartingChat: Bool,
        hasActiveStream: Bool,
        activeStreamRecoveryState: ActiveStreamRecoveryState,
        isCancellingStream: Bool,
        isScrolledNearBottom: Bool,
        activeRunStartedAt: Date?,
        isWaitingForUser: Bool = false,
        isCompacting: Bool = false
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
        case .waitingForNetwork:
            return ChatActiveRunStatusPresentation(kind: .waitingForNetwork)
        case .idle:
            break
        }

        if isWaitingForUser {
            return ChatActiveRunStatusPresentation(kind: .waitingForUser)
        }

        guard hasActiveStream else { return nil }
        return ChatActiveRunStatusPresentation(kind: .active, startedAt: activeRunStartedAt, isCompacting: isCompacting)
    }
}

enum ChatWorkingRowPolicy {
    static func startedAt(
        activeRunStartedAt: Date?,
        isCancellingStream: Bool,
        hasPendingClarificationPrompt: Bool
    ) -> Date? {
        guard let activeRunStartedAt, !isCancellingStream, !hasPendingClarificationPrompt else {
            return nil
        }
        return activeRunStartedAt
    }
}

enum ChatWorkingRowLabel {
    static func text(startedAt: Date, now: Date, isCompacting: Bool) -> String {
        let elapsed = ChatWorkingElapsedFormatter.label(startedAt: startedAt, now: now)
        return isCompacting ? String(localized: "Compacting context · \(elapsed)") : String(localized: "Working for \(elapsed)")
    }

    static func accessibilityLabel(startedAt: Date, now: Date, isCompacting: Bool) -> String {
        let elapsed = ChatWorkingElapsedFormatter.spokenLabel(startedAt: startedAt, now: now)
        return isCompacting
            ? String(localized: "Hermes is compacting context, working for \(elapsed)")
            : String(localized: "Hermes has been working for \(elapsed)")
    }
}

enum ChatWorkingElapsedFormatter {
    static func label(startedAt: Date, now: Date) -> String {
        label(seconds: now.timeIntervalSince(startedAt))
    }

    static func spokenLabel(startedAt: Date, now: Date) -> String {
        spokenLabel(seconds: now.timeIntervalSince(startedAt))
    }

    static func label(seconds: TimeInterval) -> String {
        Duration.seconds(wholeSeconds(seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    static func spokenLabel(seconds: TimeInterval) -> String {
        Duration.seconds(wholeSeconds(seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int(seconds.rounded(.down)))
    }
}

enum ResponseCompletionOutcome: Equatable {
    case completed
    case failed

    init?(_ status: AgentRunActivityStatus) {
        switch status {
        case .complete: self = .completed
        case .failed: self = .failed
        default: return nil
        }
    }

    init?(ending: TranscriptTurnRunOutcome.Ending) {
        switch ending {
        case .completed: self = .completed
        case .failed: self = .failed
        case .cancelled: return nil
        }
    }

    var body: String {
        switch self {
        case .completed: String(localized: "Response complete")
        case .failed: String(localized: "Response failed")
        }
    }
}

enum ResponseCompletionNotificationPolicy {
    static func shouldSchedule(
        preferenceEnabled: Bool,
        authorizationStatus: UNAuthorizationStatus,
        sceneIsActive: Bool
    ) -> Bool {
        guard preferenceEnabled,
              authorizationStatus.allowsResponseCompletionNotifications,
              !sceneIsActive else {
            return false
        }

        return true
    }
}

struct ResponseCompletionNotificationRequest: Equatable {
    static let source = "local"

    let sessionID: String?
    let server: URL
    let title: String
    let outcome: ResponseCompletionOutcome
    let hermesProfile: String?

    init(sessionID: String?, server: URL, title: String, outcome: ResponseCompletionOutcome, hermesProfile: String? = nil) {
        self.sessionID = sessionID?.isEmpty == false ? sessionID : nil
        self.server = server
        self.title = AgentRunActivitySanitizer.sessionTitle(title)
        self.outcome = outcome
        self.hermesProfile = hermesProfile
    }

    var body: String { outcome.body }

    var identifier: String {
        "run-alert-\(Self.serverHash(server).prefix(16))-\(sessionID ?? "")"
    }

    var threadIdentifier: String { identifier }

    var userInfo: [String: String] {
        var info = ["server_hash": Self.serverHash(server), "source": Self.source]
        info["session_id"] = sessionID
        info["hermes_profile"] = hermesProfile
        return info
    }

    static func serverHash(_ server: URL) -> String {
        SHA256.hash(data: Data(server.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func destination(userInfo: [AnyHashable: Any], servers: [URL]) -> URL? {
        guard userInfo["source"] as? String == source,
              let hash = userInfo["server_hash"] as? String,
              let sessionID = (userInfo["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let server = servers.first(where: { serverHash($0) == hash })
        else { return nil }
        if let profile = userInfo["hermes_profile"] as? String {
            return HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: profile, key: sessionID))
        }
        return HermesDeepLink.webuiSessionURL(server: server, sessionID: sessionID)
    }
}

struct ResponseCompletionNotificationCompletionContext: Equatable {
    let sceneIsActive: Bool
}

struct ResponseCompletionNotificationTracker {
    private var lastHandledRunEndTrigger = 0

    func shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: Int) -> Bool {
        runEndTrigger <= lastHandledRunEndTrigger
    }

    mutating func completionContext(
        runEndTrigger: Int,
        sceneIsActive: Bool
    ) -> ResponseCompletionNotificationCompletionContext? {
        guard runEndTrigger > lastHandledRunEndTrigger else {
            return nil
        }

        lastHandledRunEndTrigger = runEndTrigger
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
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = request.threadIdentifier
        content.userInfo = request.userInfo

        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
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

    struct EnableResult: Equatable {
        let isEnabled: Bool
        let authorizationStatus: UNAuthorizationStatus
        let message: String?
    }

    @MainActor
    static func enable(
        defaults: UserDefaults = .standard,
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> EnableResult {
        var status = await scheduler.authorizationStatus()
        let isEnabled: Bool
        let message: String?
        switch status {
        case .authorized, .provisional, .ephemeral:
            isEnabled = true
            message = nil
        case .notDetermined where defaults.bool(forKey: ResponseCompletionNotifications.hasRequestedPermissionKey):
            isEnabled = false
            message = String(localized: "Permission not requested.")
        case .notDetermined:
            defaults.set(true, forKey: ResponseCompletionNotifications.hasRequestedPermissionKey)
            let granted = await scheduler.requestAuthorization()
            status = await scheduler.authorizationStatus()
            isEnabled = granted && status.allowsResponseCompletionNotifications
            message = isEnabled ? nil : permissionLabel(status)
        case .denied:
            isEnabled = false
            message = permissionLabel(status)
        @unknown default:
            isEnabled = false
            message = String(localized: "Notifications unavailable.")
        }
        defaults.set(isEnabled, forKey: ResponseCompletionNotifications.isEnabledKey)
        return EnableResult(isEnabled: isEnabled, authorizationStatus: status, message: message)
    }

    static func permissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "iOS notifications allowed.")
        case .notDetermined:
            return String(localized: "iOS permission not requested.")
        case .denied:
            return String(localized: "iOS notifications disabled.")
        @unknown default:
            return String(localized: "Notifications unavailable.")
        }
    }

    @MainActor @discardableResult
    static func scheduleRunEndedIfAllowed(
        _ outcome: ResponseCompletionOutcome,
        sessionID: String?,
        hermesProfile: String? = nil,
        title: String,
        server: URL,
        preferenceEnabled: Bool,
        sceneIsActive: Bool,
        isCurrent: @MainActor () -> Bool = { true },
        isPushPaired: @MainActor (URL) -> Bool = { @MainActor in PushRegistrar.shared?.pairing(for: $0) != nil },
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> Bool {
        let status = await authorizationStatus(scheduler: scheduler)
        guard isCurrent() else { return false }
        if isPushPaired(server) { return false }
        guard ResponseCompletionNotificationPolicy.shouldSchedule(
            preferenceEnabled: preferenceEnabled,
            authorizationStatus: status,
            sceneIsActive: sceneIsActive
        ) else {
            return false
        }

        await scheduler.schedule(ResponseCompletionNotificationRequest(
            sessionID: sessionID, server: server, title: title, outcome: outcome, hermesProfile: hermesProfile))
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

enum StreamingSendBehavior: String, CaseIterable, Identifiable, SendChoice {
    case steer
    case interrupt
    case queue

    static let storageKey = "streamingSendBehavior"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer:
            String(localized: "Steer")
        case .interrupt:
            String(localized: "Stop and send")
        case .queue:
            String(localized: "Queue")
        }
    }

    var systemImage: String {
        switch self {
        case .steer:
            "arrow.turn.up.right"
        case .interrupt:
            "stop.circle"
        case .queue:
            "text.append"
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
