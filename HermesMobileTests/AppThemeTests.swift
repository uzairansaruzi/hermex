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

    func testZoraWordmarkUsesZoraAccessibleBranding() {
        XCTAssertEqual(ZoraWordmark.text, "Zora")
        XCTAssertEqual(ZoraWordmark.accessibilityLabel, "Zora")
        XCTAssertLessThan(ZoraWordmark.tracking, 0)
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
    func testAllowsEnabledAuthorizedNormalCompletionWhileSceneInactive() {
        XCTAssertTrue(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: false
            )
        )
    }

    func testBlocksForegroundCompletion() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: true
            )
        )
    }

    func testBlocksCancelledOrFailedCompletion() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: false,
                sceneIsActive: false
            )
        )
    }

    func testBlocksWhenPreferenceOrPermissionDisallows() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: false,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: false
            )
        )

        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .denied,
                completedNormally: true,
                sceneIsActive: false
            )
        )
    }
}

final class ResponseCompletionNotificationServiceTests: XCTestCase {
    func testRequestCarriesOnlySessionIDPayload() {
        XCTAssertEqual(
            ResponseCompletionNotificationRequest(sessionID: "session-abc").userInfo,
            ["session_id": "session-abc"]
        )
        XCTAssertEqual(ResponseCompletionNotificationRequest(sessionID: "").userInfo, [:])
        XCTAssertEqual(ResponseCompletionNotificationRequest(sessionID: nil).userInfo, [:])
    }

    func testSchedulesAllowedResponseCompletionWithSessionID() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
            sessionID: "session-abc",
            preferenceEnabled: true,
            completedNormally: true,
            sceneIsActive: false,
            scheduler: scheduler
        )

        XCTAssertTrue(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertEqual(scheduler.scheduledRequests, [ResponseCompletionNotificationRequest(sessionID: "session-abc")])
    }

    func testDoesNotScheduleBlockedResponseCompletion() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
            sessionID: "session-abc",
            preferenceEnabled: true,
            completedNormally: true,
            sceneIsActive: true,
            scheduler: scheduler
        )

        XCTAssertFalse(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertTrue(scheduler.scheduledRequests.isEmpty)
    }

    func testRequestAuthorizationUsesInjectedScheduler() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .notDetermined, requestAuthorizationResult: true)

        let granted = await ResponseCompletionNotificationService.requestAuthorization(scheduler: scheduler)

        XCTAssertTrue(granted)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 1)
    }
}

final class ResponseCompletionNotificationTrackerTests: XCTestCase {
    func testDefersBackgroundTaskEndUntilNormalCompletionContextIsHandled() {
        var tracker = ResponseCompletionNotificationTracker()

        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 0))
        XCTAssertFalse(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 1))

        let context = tracker.completionContext(completionTrigger: 1, sceneIsActive: false)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: false))
        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 1))
        // The same completion trigger is consumed only once.
        XCTAssertNil(tracker.completionContext(completionTrigger: 1, sceneIsActive: false))
    }

    func testCompletionContextCapturesSceneStateAtCompletion() {
        var tracker = ResponseCompletionNotificationTracker()

        let context = tracker.completionContext(completionTrigger: 1, sceneIsActive: true)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: true))
    }

    func testInactiveStreamWithoutCompletionTriggerCanEndBackgroundTaskImmediately() {
        let tracker = ResponseCompletionNotificationTracker()

        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 0))
    }
}

private final class SpyResponseCompletionNotificationScheduler: ResponseCompletionNotificationScheduling {
    private let status: UNAuthorizationStatus
    private let requestAuthorizationResult: Bool
    private(set) var authorizationStatusCallCount = 0
    private(set) var requestAuthorizationCallCount = 0
    private(set) var scheduledRequests: [ResponseCompletionNotificationRequest] = []

    init(
        status: UNAuthorizationStatus,
        requestAuthorizationResult: Bool = false
    ) {
        self.status = status
        self.requestAuthorizationResult = requestAuthorizationResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusCallCount += 1
        return status
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        return requestAuthorizationResult
    }

    func schedule(_ request: ResponseCompletionNotificationRequest) async {
        scheduledRequests.append(request)
    }
}
