import XCTest
@testable import HermesMobile

final class SessionHapticsTests: XCTestCase {
    @MainActor
    func testHapticsRespectEnabledSetting() {
        var feedback: [SessionHapticFeedback] = []

        SessionHaptics.sessionCreated(isEnabled: false) { feedback.append($0) }
        SessionHaptics.pinStateChanged(isEnabled: false) { feedback.append($0) }
        SessionHaptics.archiveStateChanged(isEnabled: false) { feedback.append($0) }
        SessionHaptics.sessionDeleted(isEnabled: false) { feedback.append($0) }
        SessionHaptics.sessionRenamed(isEnabled: false) { feedback.append($0) }

        XCTAssertTrue(feedback.isEmpty)
    }
}
