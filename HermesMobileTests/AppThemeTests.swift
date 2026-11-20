import SwiftUI
import XCTest
import UserNotifications
@testable import HermesMobile

final class AppThemeTests: XCTestCase {
    func testStoredValueFallsBackToSystemForUnknownRawValue() {
        XCTAssertEqual(AppTheme.storedValue("unexpected"), .system)
    }

    func testHeaderLogoColorNormalizesStoredHexValues() {
        XCTAssertEqual(HeaderLogoColor.normalizedHex("#5b7cff"), "#5B7CFF")
        XCTAssertEqual(HeaderLogoColor.normalizedHex(" ff3b30 "), "#FF3B30")
        XCTAssertNil(HeaderLogoColor.normalizedHex("#123"))
        XCTAssertNil(HeaderLogoColor.normalizedHex("#GG0000"))
    }

    func testHeaderLogoColorFormatsRGBComponentsAsHex() {
        XCTAssertEqual(HeaderLogoColor.hexString(red: 1, green: 0, blue: 0.5), "#FF0080")
        XCTAssertEqual(HeaderLogoColor.hexString(red: -0.2, green: 1.2, blue: 0), "#00FF00")
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
}

final class ChatLayoutDirectionSettingsTests: XCTestCase {
    func testRTLChatLayoutKeyIsStable() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey,
            "chatTranscript.rtlChatLayoutEnabled"
        )
    }

    func testRightToLeftLanguageDetectionUsesPrimaryPreferredLanguage() {
        for rtl in [["ar-SA", "en-US"], ["he"], ["fa-IR"], ["ur"]] {
            XCTAssertTrue(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: rtl),
                "expected RTL for \(rtl)"
            )
        }
        for ltr in [["en-US"], ["de"], ["de", "ar"], []] {
            XCTAssertFalse(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: ltr),
                "expected LTR for \(ltr)"
            )
        }
    }
}

final class CodeBlockWrappingSettingsTests: XCTestCase {
    func testPlainFormatterSegmentsRejoinLosslessly() throws {
        let longLine = String(repeating: "abcde", count: 240)
        let lines = MarkdownPlainCodeFormatter.lines(in: longLine)

        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertGreaterThan(line.segments.count, 1, "A 1200-char line should split into multiple segments")
        XCTAssertEqual(line.segments.map(\.text).joined(), longLine)
    }

    func testAttributedFormatterSegmentsRejoinLosslesslyPreservingAttributes() throws {
        let source = String(repeating: "x", count: 1200)
        let attributed = NSMutableAttributedString(string: source)
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

    func testRequestCarriesTitleOutcomeAndServerHash() {
        let request = ResponseCompletionNotificationRequest(
            sessionID: "session-abc", server: serverA, title: "  Deploy notes\n", outcome: .failed)

        XCTAssertEqual(request.title, "Deploy notes")
        XCTAssertEqual(request.body, "Response failed")
        XCTAssertEqual(request.userInfo, [
            "session_id": "session-abc",
            "server_hash": "93d446a9d8ca42b500faf019713f245eaf0377bd89add0676ece0b22d3ebfb02",
            "source": "local"
        ])
        XCTAssertEqual(request.identifier, "run-alert-93d446a9d8ca42b5-session-abc")
        XCTAssertEqual(request.threadIdentifier, request.identifier)
    }

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
        XCTAssertNil(tracker.completionContext(runEndTrigger: 1, sceneIsActive: false))
    }

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
}

final class SpyResponseCompletionNotificationScheduler: ResponseCompletionNotificationScheduling {
    private var status: UNAuthorizationStatus
    private let requestAuthorizationResult: Bool
    private let statusAfterRequest: UNAuthorizationStatus?
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

final class CodeWrapMigrationTests: XCTestCase {
    func testEitherSettingBeingOnStaysOn() throws {
        let suite = "CodeWrapMigrationTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyKey = "workspace.sourceViewer.wrapsLines"

        defaults.set(true, forKey: legacyKey)
        CodeDisplaySettings.migrateWrapSetting(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: CodeDisplaySettings.wrapsLinesKey))
        XCTAssertNil(defaults.object(forKey: legacyKey))

        defaults.set(false, forKey: legacyKey)
        CodeDisplaySettings.migrateWrapSetting(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: CodeDisplaySettings.wrapsLinesKey), "A legacy off doesn't undo chat's on")
    }
}

@MainActor
final class AppearanceTextAndCodeSizeTests: XCTestCase {
    private func settle(_ window: UIWindow) async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
    }

    func testAStopResizesTheSceneAndTheFirstStopFollowsTheIPhone() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let probe = DynamicTypeProbe()
        let controller = UIHostingController(rootView: DynamicTypeProbeView(probe: probe))
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: AppTextSize.storageKey)
            AppTextSize.applyStoredSize(to: scene)
        }

        let stop = try XCTUnwrap(AppTextSize.stops.firstIndex(of: .accessibility3))
        UserDefaults.standard.set(stop, forKey: AppTextSize.storageKey)
        AppTextSize.applyStoredSizeToConnectedScenes()
        await settle(window)
        XCTAssertEqual(probe.size, .accessibility3)
        XCTAssertEqual(
            try XCTUnwrap(textView.font).pointSize,
            UIFont.preferredFont(forTextStyle: .body, at: .accessibility3).pointSize
        )

        UserDefaults.standard.set(0, forKey: AppTextSize.storageKey)
        AppTextSize.applyStoredSizeToConnectedScenes()
        await settle(window)
        XCTAssertEqual(window.traitCollection.preferredContentSizeCategory, UIApplication.shared.preferredContentSizeCategory)
        XCTAssertEqual(probe.size, DynamicTypeSize(window.traitCollection.preferredContentSizeCategory))
    }

    func testCustomCodeSizeResizesASettledReplysCodeBlock() async throws {
        let reply = ChatMessage(
            role: "assistant",
            content: "```swift\nlet value = 1\nlet other = 2\n```",
            timestamp: 1,
            messageId: "custom-code-size"
        )
        UserDefaults.standard.removeObject(forKey: CodeDisplaySettings.customSizeKey)
        let controller = UIHostingController(
            rootView: MessageBubbleView(message: reply, transcriptMediaCacheNamespace: "custom-code-size")
                .environment(\.dynamicTypeSize, .large)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: CodeDisplaySettings.customSizeKey)
        }
        func height() -> CGFloat { controller.sizeThatFits(in: CGSize(width: 390, height: 2000)).height }

        await settle(window)
        let followingText = height()
        XCTAssertGreaterThan(followingText, 0)

        UserDefaults.standard.set(28.0, forKey: CodeDisplaySettings.customSizeKey)
        await settle(window)
        XCTAssertGreaterThan(height(), followingText)

        UserDefaults.standard.removeObject(forKey: CodeDisplaySettings.customSizeKey)
        await settle(window)
        XCTAssertEqual(height(), followingText, accuracy: 0.5)
    }

    func testWrapSettingControlsToolOutput() async throws {
        let toolCall = ToolCall(
            name: "terminal",
            preview: String(repeating: "output ", count: 60),
            args: nil,
            isCompleted: true
        )
        let controller = UIHostingController(rootView: ToolCallDetailBodyView(toolCall: toolCall, status: .success))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: CodeDisplaySettings.wrapsLinesKey)
        }
        func height() -> CGFloat { controller.sizeThatFits(in: CGSize(width: 390, height: 2000)).height }

        UserDefaults.standard.set(false, forKey: CodeDisplaySettings.wrapsLinesKey)
        await settle(window)
        let unwrapped = height()

        UserDefaults.standard.set(true, forKey: CodeDisplaySettings.wrapsLinesKey)
        await settle(window)
        XCTAssertGreaterThan(height(), unwrapped + 60, "Wrapped, the line takes several rows")
    }
}

@MainActor
private final class DynamicTypeProbe {
    var size: DynamicTypeSize?
}

private struct DynamicTypeProbeView: View {
    let probe: DynamicTypeProbe
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let _ = (probe.size = dynamicTypeSize)
        Color.clear
    }
}
