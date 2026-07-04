import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class SessionIdentityTests: XCTestCase {
    func testSessionRowDisplayTitlePreservesLongTitleAndFallsBackForBlankTitle() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let longTitle = "A very long planning title that needs to remain available from the session context menu"
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-long",
              "title": "\(longTitle)"
            }
            """.utf8)
        )
        let untitled = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-blank",
              "title": "   "
            }
            """.utf8)
        )

        XCTAssertEqual(SessionRowView.displayTitle(for: session), longTitle)
        XCTAssertEqual(SessionRowView.displayTitle(for: untitled), "Untitled Session")
    }

    func testSessionRowActiveStreamingUsesStreamingFlagOrActiveStreamID() {
        XCTAssertTrue(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "streaming", isStreaming: true)))
        XCTAssertTrue(
            SessionRowView.isActiveStreaming(
                SessionSummary(sessionId: "stream-id", activeStreamId: "stream-123", isStreaming: false)
            )
        )
    }

    func testSessionRowActiveStreamingIsFalseWhenNoActiveSignalExists() {
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "idle")))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "finished", isStreaming: false)))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "empty-stream", activeStreamId: "")))
        XCTAssertFalse(SessionRowView.isActiveStreaming(SessionSummary(sessionId: "blank-stream", activeStreamId: "   ")))
    }

    func testSessionRowScheduledSessionUsesCronSignals() {
        XCTAssertTrue(SessionRowView.isScheduledSession(SessionSummary(sessionId: "cron_job123_20260702_120000")))
        XCTAssertTrue(SessionRowView.isScheduledSession(SessionSummary(sessionId: "scheduled", sourceTag: "cron")))
        XCTAssertFalse(SessionRowView.isScheduledSession(SessionSummary(sessionId: "regular", sourceTag: "chat")))
    }

    func testSessionRowMetadataLabelUsesVisiblePartsAndWorkspaceBasename() {
        let session = SessionSummary(
            sessionId: "metadata",
            workspace: "/Users/example/hermes-mobile",
            messageCount: 2
        )

        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: true),
            "2 messages • hermes-mobile"
        )
        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: false),
            "2 messages"
        )
        XCTAssertEqual(
            SessionRowView.metadataLabel(for: session, showsMessageCount: false, showsWorkspace: true),
            "hermes-mobile"
        )
    }

    func testSessionRowMetadataLabelOmitsHiddenOrUnavailableParts() {
        let session = SessionSummary(
            sessionId: "metadata-empty",
            workspace: "   ",
            messageCount: -1
        )

        XCTAssertNil(SessionRowView.metadataLabel(for: session, showsMessageCount: true, showsWorkspace: true))
        XCTAssertNil(SessionRowView.metadataLabel(for: session, showsMessageCount: false, showsWorkspace: false))
    }

    func testSessionRowStateBadgeKindsKeepScheduledStatusOutOfTitleIndentation() {
        let session = SessionSummary(sessionId: "cron_job123_20260702_120000")

        XCTAssertEqual(
            SessionRowView.stateBadgeKinds(for: session, isViewingCachedData: true).map(\.title),
            ["Scheduled", "Cached"]
        )
        XCTAssertEqual(
            SessionRowView.stateBadgeKinds(for: SessionSummary(sessionId: "plain"), isViewingCachedData: false),
            []
        )
    }

    func testSessionRowAccessibilityStateLabelsIncludeStreamingPinnedAndCachedState() {
        let session = SessionSummary(
            sessionId: "stateful",
            pinned: true,
            activeStreamId: "stream-123",
            isStreaming: false,
            sourceTag: "cron"
        )

        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: session, isViewingCachedData: true),
            ["Streaming", "Pinned", "Scheduled", "Cached"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: SessionSummary(sessionId: "plain"), isViewingCachedData: false),
            []
        )
    }

    func testSessionSummaryFallbackIDIsDeterministicWithoutSessionID() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "title": "Older Session",
              "created_at": 1770000000
            }
            """.utf8)
        )

        XCTAssertEqual(session.id, "session-Older Session-1770000000.0")
        XCTAssertEqual(session.id, "session-Older Session-1770000000.0")
    }

    func testSessionDetailFallbackIDIsDeterministicWithoutSessionID() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let session = try decoder.decode(
            SessionDetail.self,
            from: Data("""
            {
              "title": "Legacy Session",
              "updated_at": 1770000100
            }
            """.utf8)
        )

        XCTAssertEqual(session.id, "session-Legacy Session-1770000100.0")
        XCTAssertEqual(session.id, "session-Legacy Session-1770000100.0")
    }
}

final class SessionSidebarDisclosureSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionSidebarDisclosureSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testWikiTopLevelDestinationIsNativeUtilityDestination() {
        XCTAssertEqual(SessionListUtilityDestination.wiki.id, .wiki)
    }

    func testDisclosureStatesDefaultToCollapsedWhenUnset() {
        XCTAssertNil(defaults.object(forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey))
        XCTAssertNil(defaults.object(forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey))
        XCTAssertFalse(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))
    }

    func testDisclosureStatesRoundTripThroughUserDefaults() {
        defaults.set(true, forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey)
        defaults.set(false, forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey)

        XCTAssertTrue(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertFalse(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))

        defaults.set(false, forKey: SessionSidebarDisclosureSettings.profilesAreExpandedKey)
        defaults.set(true, forKey: SessionSidebarDisclosureSettings.projectsAreExpandedKey)

        XCTAssertFalse(SessionSidebarDisclosureSettings.profilesAreExpanded(in: defaults))
        XCTAssertTrue(SessionSidebarDisclosureSettings.projectsAreExpanded(in: defaults))
    }
}

/// The avatar long-press server switcher's menu contents (#283). The switch
/// action itself is #17's `AuthManager.switchActiveServer`, covered by
/// `AuthManagerStateTests`; these cover the pure model that decides what the
/// menu shows and which server is marked active.
final class AvatarServerSwitcherModelTests: XCTestCase {
    private func makeAccount(id: String, displayName: String = "") -> ServerAccount {
        ServerAccount(
            id: id,
            urlString: id,
            displayName: displayName,
            initials: "",
            headerLogoColorHex: HeaderLogoColor.defaultHex,
            customHeadersRef: id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMarksTheActiveServerAmongMultipleAndPreservesOrder() {
        let model = AvatarServerSwitcherModel(
            servers: [
                makeAccount(id: "https://a.test", displayName: "Alpha"),
                makeAccount(id: "https://b.test", displayName: "Bravo")
            ],
            activeServerID: "https://b.test"
        )

        XCTAssertEqual(model.entries.map(\.id), ["https://a.test", "https://b.test"])
        XCTAssertEqual(model.entries.map(\.displayName), ["Alpha", "Bravo"])
        XCTAssertEqual(model.entries.map(\.isActive), [false, true])
        XCTAssertEqual(model.activeID, "https://b.test")
    }

    func testSingleServerIsMarkedActive() {
        // A single-server install still gets its one server marked active, so the
        // constant "Add Server…"/"Manage Servers" actions are reachable from the
        // same menu (#283 discoverability AC).
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://only.test", displayName: "Only")],
            activeServerID: "https://only.test"
        )

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(model.entries[0].isActive)
        XCTAssertEqual(model.activeID, "https://only.test")
    }

    func testFallsBackToHostWhenDisplayNameIsEmpty() {
        let model = AvatarServerSwitcherModel(
            servers: [
                makeAccount(id: "https://hermes.example.com:8080", displayName: ""),
                makeAccount(id: "https://named.test", displayName: "Named")
            ],
            activeServerID: "https://hermes.example.com:8080"
        )

        XCTAssertEqual(model.entries[0].displayName, "hermes.example.com")
        XCTAssertEqual(model.entries[1].displayName, "Named")
    }

    func testNoEntryIsActiveWhenActiveIDMatchesNoServer() {
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://a.test", displayName: "Alpha")],
            activeServerID: nil
        )

        XCTAssertFalse(model.entries.contains { $0.isActive })
        XCTAssertNil(model.activeID)
    }

    func testEntryCarriesItsAccountForTheSwitchAction() {
        let bravo = makeAccount(id: "https://b.test", displayName: "Bravo")
        let model = AvatarServerSwitcherModel(
            servers: [makeAccount(id: "https://a.test", displayName: "Alpha"), bravo],
            activeServerID: "https://a.test"
        )

        XCTAssertEqual(model.entries[1].account, bravo)
    }
}
