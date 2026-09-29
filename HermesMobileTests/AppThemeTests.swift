import SwiftUI
import XCTest
import UserNotifications
@testable import HermesMobile

final class AppThemeTests: XCTestCase {
    func testStoredValueFallsBackToSystemForUnknownRawValue() {
        XCTAssertEqual(AppTheme.storedValue("unexpected"), .system)
    }

    func testThemeMapsToExpectedColorScheme() {
        XCTAssertNil(AppTheme.system.colorScheme)
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testHeaderLogoColorNormalizesStoredHexValues() {
        XCTAssertEqual(HeaderLogoColor.normalizedHex("#5b7cff"), "#5B7CFF")
        XCTAssertEqual(HeaderLogoColor.normalizedHex(" ff3b30 "), "#FF3B30")
        XCTAssertNil(HeaderLogoColor.normalizedHex("#123"))
        XCTAssertNil(HeaderLogoColor.normalizedHex("#GG0000"))
    }

    func testHeaderLogoColorDisplayNameUsesPresetOrCustomFallback() {
        XCTAssertEqual(HeaderLogoColor.displayName(for: "#FFD700"), "Yellow")
        XCTAssertEqual(HeaderLogoColor.displayName(for: "#123456"), "Custom")
        XCTAssertEqual(HeaderLogoColor.displayName(for: "not-a-color"), "Yellow")
    }

    func testHeaderLogoColorFormatsRGBComponentsAsHex() {
        XCTAssertEqual(HeaderLogoColor.hexString(red: 1, green: 0, blue: 0.5), "#FF0080")
        XCTAssertEqual(HeaderLogoColor.hexString(red: -0.2, green: 1.2, blue: 0), "#00FF00")
    }

    func testRTLLayoutHorizontalOffsetMirrorsUnderRightToLeft() {
        XCTAssertEqual(RTLLayout.horizontalOffset(6, isRightToLeft: false), 6)
        XCTAssertEqual(RTLLayout.horizontalOffset(6, isRightToLeft: true), -6)
        XCTAssertEqual(RTLLayout.horizontalOffset(-4, isRightToLeft: true), 4)
        XCTAssertEqual(RTLLayout.horizontalOffset(0, isRightToLeft: true), 0)
    }

    func testRTLDisclosureChevronRotationReversesUnderRightToLeft() {
        // Collapsed: no rotation regardless of direction.
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: false, isRightToLeft: false), 0)
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: false, isRightToLeft: true), 0)
        // Expanded: clockwise in LTR, counter-clockwise in RTL so it still points down.
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: true, isRightToLeft: false), 90)
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: true, isRightToLeft: true), -90)
    }

    func testHeaderLogoColorChoosesReadableForeground() {
        XCTAssertTrue(HeaderLogoColor.prefersDarkForeground(for: "#FFD700"))
        XCTAssertTrue(HeaderLogoColor.prefersDarkForeground(for: "#FFFFFF"))
        XCTAssertFalse(HeaderLogoColor.prefersDarkForeground(for: "#5B7CFF"))
        XCTAssertFalse(HeaderLogoColor.prefersDarkForeground(for: "#AF52DE"))
    }

    func testSessionIdentityInitialsPreferStoredValueThenDisplayName() {
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "Ada Lovelace",
                storedInitials: " hm ",
                fallbackFullName: "Fallback Person"
            ),
            "HM"
        )
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "Ada Lovelace",
                storedInitials: "",
                fallbackFullName: "Fallback Person"
            ),
            "AL"
        )
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "",
                storedInitials: "",
                fallbackFullName: ""
            ),
            "UZ"
        )
    }

    func testSessionIdentityInitialsNormalizeUserInput() {
        XCTAssertEqual(SessionIdentitySettings.normalizedInitials(" u-z!9 "), "UZ9")
        XCTAssertEqual(SessionIdentitySettings.normalizedInitials("abcd"), "ABC")
    }
}

final class PrimaryActionTintSettingsTests: XCTestCase {
    func testStorageKeyIsStable() {
        XCTAssertEqual(
            PrimaryActionTintSettings.isEnabledKey,
            "appearance.tintsPrimaryActionsWithThemeColor"
        )
    }

    func testUsesThemeColorRequiresBothEnabledAndInteractive() {
        XCTAssertTrue(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: true, controlIsEnabled: true)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: false, controlIsEnabled: true)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: true, controlIsEnabled: false)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: false, controlIsEnabled: false)
        )
    }
}

final class ChatLayoutDirectionSettingsTests: XCTestCase {
    func testRTLChatLayoutKeyIsStable() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey,
            "chatTranscript.rtlChatLayoutEnabled"
        )
    }

    func testChatLayoutDirectionFollowsToggle() {
        XCTAssertEqual(ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: true), .rightToLeft)
        XCTAssertEqual(ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: false), .leftToRight)
    }

    func testRightToLeftLanguageDetectionUsesPrimaryPreferredLanguage() {
        // RTL primaries auto-enable, including region-qualified identifiers.
        for rtl in [["ar-SA", "en-US"], ["he"], ["fa-IR"], ["ur"]] {
            XCTAssertTrue(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: rtl),
                "expected RTL for \(rtl)"
            )
        }
        // LTR primaries stay off — even when an RTL language is further down the list.
        for ltr in [["en-US"], ["de"], ["de", "ar"], []] {
            XCTAssertFalse(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: ltr),
                "expected LTR for \(ltr)"
            )
        }
    }
}

final class CodeBlockWrappingSettingsTests: XCTestCase {
    func testWrapsCodeBlockLinesKeyIsStable() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey,
            "chatTranscript.wrapsCodeBlockLines"
        )
    }

    /// Wrap mode concatenates a line's 500-char segments back into one `Text`, so
    /// joining them must reproduce the source line exactly (no dropped/duplicated
    /// characters) even when the line is split into several segments.
    func testPlainFormatterSegmentsRejoinLosslessly() throws {
        let longLine = String(repeating: "abcde", count: 240) // 1200 chars > 2x maxSegmentLength
        let lines = MarkdownPlainCodeFormatter.lines(in: longLine)

        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertGreaterThan(line.segments.count, 1, "A 1200-char line should split into multiple segments")
        XCTAssertEqual(line.segments.map(\.text).joined(), longLine)
    }

    /// The highlighted wrap path concatenates `MarkdownAttributedCodeFormatter`
    /// segments back into one `Text`, so the segments must rejoin losslessly *and*
    /// preserve their syntax-highlight attributes — including across a 500-char
    /// segment boundary.
    func testAttributedFormatterSegmentsRejoinLosslesslyPreservingAttributes() throws {
        let source = String(repeating: "x", count: 1200)
        let attributed = NSMutableAttributedString(string: source)
        // An attribute spanning the first 500-char boundary (480..<520) must survive.
        attributed.addAttribute(.kern, value: NSNumber(value: 3), range: NSRange(location: 480, length: 40))

        let lines = MarkdownAttributedCodeFormatter.lines(in: attributed)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertGreaterThan(line.segments.count, 1, "A 1200-char line should split into multiple segments")

        let rejoined = NSMutableAttributedString()
        for segment in line.segments {
            rejoined.append(segment.attributedText)
        }

        XCTAssertEqual(rejoined.string, source)
        XCTAssertEqual(rejoined.attribute(.kern, at: 490, effectiveRange: nil) as? NSNumber, NSNumber(value: 3))
        XCTAssertEqual(rejoined.attribute(.kern, at: 510, effectiveRange: nil) as? NSNumber, NSNumber(value: 3))
        XCTAssertNil(rejoined.attribute(.kern, at: 600, effectiveRange: nil))
    }
}

final class ResponseCompletionNotificationPolicyTests: XCTestCase {
    func testAllowsEnabledAuthorizedRunEndWhileSceneInactive() {
        XCTAssertTrue(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                sceneIsActive: false
            )
        )
    }

    func testBlocksForegroundRunEnd() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                sceneIsActive: true
            )
        )
    }

    // #862: a completed or failed run can alert; a stopped one has no outcome to alert with.
    func testOnlyCompletedAndFailedRunsHaveAnAlertOutcome() {
        XCTAssertEqual(ResponseCompletionOutcome(.complete), .completed)
        XCTAssertEqual(ResponseCompletionOutcome(.failed), .failed)
        XCTAssertNil(ResponseCompletionOutcome(.cancelled))
        XCTAssertNil(ResponseCompletionOutcome(.waitingForApproval))
    }

    func testBlocksWhenPreferenceOrPermissionDisallows() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: false,
                authorizationStatus: .authorized,
                sceneIsActive: false
            )
        )

        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .denied,
                sceneIsActive: false
            )
        )
    }
}

@MainActor
final class ResponseCompletionNotificationServiceTests: XCTestCase {
    private let serverA = URL(string: "https://a.example.com")!
    private let serverB = URL(string: "https://b.example.com")!

    // #862: the alert names the chat, says how the run ended, and carries a hash of
    // its server rather than the URL. No `install_hash`, so it is never read as a
    // relay push (#653).
    func testRequestCarriesTitleOutcomeAndServerHash() {
        let request = ResponseCompletionNotificationRequest(
            sessionID: "session-abc", server: serverA, title: "  Deploy notes\n", outcome: .failed)

        XCTAssertEqual(request.title, "Deploy notes")
        XCTAssertEqual(request.body, "Response failed")
        XCTAssertEqual(request.userInfo, [
            "session_id": "session-abc",
            // printf 'https://a.example.com' | shasum -a 256
            "server_hash": "93d446a9d8ca42b500faf019713f245eaf0377bd89add0676ece0b22d3ebfb02",
            "source": "local"
        ])
        XCTAssertEqual(request.identifier, "run-alert-93d446a9d8ca42b5-session-abc")
        XCTAssertEqual(request.threadIdentifier, request.identifier)
    }

    func testTitleFallsBackToHermesSession() {
        let request = ResponseCompletionNotificationRequest(
            sessionID: "session-abc", server: serverA, title: " \n ", outcome: .completed)

        XCTAssertEqual(request.title, "Hermes session")
        XCTAssertEqual(request.body, "Response complete")
    }

    // #862: a newer alert for the same chat replaces the last one; the same session ID
    // on another server is a different chat.
    func testIdentifierIsStablePerChatAndDistinctPerServer() {
        let failed = ResponseCompletionNotificationRequest(
            sessionID: "same-id", server: serverA, title: "A", outcome: .failed)
        let retried = ResponseCompletionNotificationRequest(
            sessionID: "same-id", server: serverA, title: "A renamed", outcome: .completed)
        let otherServer = ResponseCompletionNotificationRequest(
            sessionID: "same-id", server: serverB, title: "A", outcome: .failed)

        XCTAssertEqual(failed.identifier, retried.identifier)
        XCTAssertNotEqual(failed.identifier, otherServer.identifier)
        XCTAssertNotEqual(failed.threadIdentifier, otherServer.threadIdentifier)
    }

    func testSchedulesAFailedRunInTheBackground() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleRunEndedIfAllowed(
            .failed,
            sessionID: "session-abc",
            title: "Deploy notes",
            server: serverA,
            preferenceEnabled: true,
            sceneIsActive: false,
            isPushPaired: { _ in false },
            scheduler: scheduler
        )

        XCTAssertTrue(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertEqual(scheduler.scheduledRequests, [ResponseCompletionNotificationRequest(
            sessionID: "session-abc", server: serverA, title: "Deploy notes", outcome: .failed)])
    }

    // #862: a chat's alerts share one identifier, so a run end that a newer one
    // superseded while it waited must not schedule over the newer alert.
    @MainActor
    func testSkipsARunEndSupersededWhileItWaited() async {
        var latestRunEnd = 1
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized) {
            latestRunEnd = 2
        }

        let didSchedule = await ResponseCompletionNotificationService.scheduleRunEndedIfAllowed(
            .completed,
            sessionID: "session-abc",
            title: "Deploy notes",
            server: serverA,
            preferenceEnabled: true,
            sceneIsActive: false,
            isCurrent: { latestRunEnd == 1 },
            isPushPaired: { _ in false },
            scheduler: scheduler
        )

        XCTAssertFalse(didSchedule)
        XCTAssertTrue(scheduler.scheduledRequests.isEmpty)
    }

    func testDoesNotScheduleInTheForeground() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleRunEndedIfAllowed(
            .completed,
            sessionID: "session-abc",
            title: "Deploy notes",
            server: serverA,
            preferenceEnabled: true,
            sceneIsActive: true,
            isPushPaired: { _ in false },
            scheduler: scheduler
        )

        XCTAssertFalse(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertTrue(scheduler.scheduledRequests.isEmpty)
    }

    // #863: Settings' toggle and the chat's one-time offer share this enable, so the
    // prompt, the asked-once flag and the stored preference stay in step.
    @MainActor
    func testEnableAsksOnceWhenPermissionWasNeverRequested() async throws {
        let defaults = try makeDefaults()
        let scheduler = SpyResponseCompletionNotificationScheduler(
            status: .notDetermined, requestAuthorizationResult: true, statusAfterRequest: .authorized)

        let result = await ResponseCompletionNotificationService.enable(defaults: defaults, scheduler: scheduler)

        XCTAssertEqual(result, .init(isEnabled: true, authorizationStatus: .authorized, message: nil))
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 1)
        XCTAssertTrue(defaults.bool(forKey: ResponseCompletionNotifications.hasRequestedPermissionKey))
        XCTAssertTrue(defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey))
    }

    @MainActor
    func testEnableStaysOffWhenTheFirstPromptIsRefused() async throws {
        let defaults = try makeDefaults()
        let scheduler = SpyResponseCompletionNotificationScheduler(
            status: .notDetermined, requestAuthorizationResult: false, statusAfterRequest: .denied)

        let result = await ResponseCompletionNotificationService.enable(defaults: defaults, scheduler: scheduler)

        XCTAssertEqual(result, .init(isEnabled: false, authorizationStatus: .denied, message: "iOS notifications disabled."))
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 1)
        XCTAssertTrue(defaults.bool(forKey: ResponseCompletionNotifications.hasRequestedPermissionKey))
        XCTAssertFalse(defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey))
    }

    @MainActor
    func testEnableNeverAsksTwice() async throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: ResponseCompletionNotifications.hasRequestedPermissionKey)
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .notDetermined, requestAuthorizationResult: true)

        let result = await ResponseCompletionNotificationService.enable(defaults: defaults, scheduler: scheduler)

        XCTAssertEqual(result, .init(isEnabled: false, authorizationStatus: .notDetermined, message: "Permission not requested."))
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
        XCTAssertFalse(defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey))
    }

    @MainActor
    func testEnableStaysOffWithTheDeniedMessageWhenPermissionIsDenied() async throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: ResponseCompletionNotifications.isEnabledKey)
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .denied, requestAuthorizationResult: true)

        let result = await ResponseCompletionNotificationService.enable(defaults: defaults, scheduler: scheduler)

        XCTAssertEqual(result, .init(isEnabled: false, authorizationStatus: .denied, message: "iOS notifications disabled."))
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
        XCTAssertFalse(defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey))
    }

    @MainActor
    func testEnableTurnsOnWithoutAPromptWhenAlreadyAllowed() async throws {
        let defaults = try makeDefaults()
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let result = await ResponseCompletionNotificationService.enable(defaults: defaults, scheduler: scheduler)

        XCTAssertEqual(result, .init(isEnabled: true, authorizationStatus: .authorized, message: nil))
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
        XCTAssertTrue(defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ResponseCompletionNotificationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

final class ResponseCompletionNotificationTrackerTests: XCTestCase {
    func testDefersBackgroundTaskEndUntilRunEndContextIsHandled() {
        var tracker = ResponseCompletionNotificationTracker()

        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: 0))
        XCTAssertFalse(tracker.shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: 1))

        let context = tracker.completionContext(runEndTrigger: 1, sceneIsActive: false)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: false))
        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: 1))
        // The same run-end trigger is consumed only once.
        XCTAssertNil(tracker.completionContext(runEndTrigger: 1, sceneIsActive: false))
    }

    // #862: a failure after a handled completion is a new bump, so the stream going
    // inactive leaves the background task open until the failure's alert is handled.
    func testFailureBumpKeepsBackgroundTaskOpenUntilItsContextIsConsumed() {
        var tracker = ResponseCompletionNotificationTracker()
        _ = tracker.completionContext(runEndTrigger: 1, sceneIsActive: false)

        XCTAssertFalse(tracker.shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: 2))
        XCTAssertEqual(
            tracker.completionContext(runEndTrigger: 2, sceneIsActive: false),
            ResponseCompletionNotificationCompletionContext(sceneIsActive: false)
        )
        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(runEndTrigger: 2))
    }

    func testCompletionContextCapturesSceneStateAtRunEnd() {
        var tracker = ResponseCompletionNotificationTracker()

        let context = tracker.completionContext(runEndTrigger: 1, sceneIsActive: true)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: true))
    }
}

/// Shared with `NotificationOfferTests`.
final class SpyResponseCompletionNotificationScheduler: ResponseCompletionNotificationScheduling {
    private var status: UNAuthorizationStatus
    private let requestAuthorizationResult: Bool
    /// The status iOS reports once the prompt is answered; unchanged when nil.
    private let statusAfterRequest: UNAuthorizationStatus?
    /// Runs while the permission check is in flight, for work that lands meanwhile.
    private let duringAuthorizationStatus: () -> Void
    private(set) var authorizationStatusCallCount = 0
    private(set) var requestAuthorizationCallCount = 0
    private(set) var scheduledRequests: [ResponseCompletionNotificationRequest] = []

    init(
        status: UNAuthorizationStatus,
        requestAuthorizationResult: Bool = false,
        statusAfterRequest: UNAuthorizationStatus? = nil,
        duringAuthorizationStatus: @escaping () -> Void = {}
    ) {
        self.status = status
        self.requestAuthorizationResult = requestAuthorizationResult
        self.statusAfterRequest = statusAfterRequest
        self.duringAuthorizationStatus = duringAuthorizationStatus
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusCallCount += 1
        duringAuthorizationStatus()
        return status
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        if let statusAfterRequest { status = statusAfterRequest }
        return requestAuthorizationResult
    }

    func schedule(_ request: ResponseCompletionNotificationRequest) async {
        scheduledRequests.append(request)
    }
}
