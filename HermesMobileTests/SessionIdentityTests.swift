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

    func testSessionRowAccessibilityStateLabelsIncludeAttentionPinnedAndCachedState() {
        let session = SessionSummary(
            sessionId: "stateful",
            pinned: true,
            activeStreamId: "stream-123",
            isStreaming: false
        )

        // Cached rows say nothing about attention: the stream fields in a
        // cached summary are as old as the cache.
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: session, isViewingCachedData: true),
            ["Pinned", "Cached"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: session, isViewingCachedData: false),
            ["Working", "Pinned"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: SessionSummary(sessionId: "plain"), isViewingCachedData: false),
            []
        )
    }

    func testExternalSessionSourceLabelsPreferServerValueAndUseStableFallbacks() {
        let serverLabeled = SessionSummary(
            sessionId: "telegram",
            isCliSession: true,
            rawSource: "telegram",
            sessionSource: "messaging",
            sourceLabel: "Telegram Business"
        )
        let legacyTelegram = SessionSummary(
            sessionId: "legacy-telegram",
            rawSource: "telegram",
            sessionSource: "messaging"
        )
        let legacyCLI = SessionSummary(sessionId: "cli", sourceTag: "cli")

        XCTAssertTrue(serverLabeled.requiresExternalImport)
        XCTAssertEqual(serverLabeled.sourceDisplayLabel, "Telegram Business")
        XCTAssertTrue(legacyTelegram.requiresExternalImport)
        XCTAssertEqual(legacyTelegram.sourceDisplayLabel, "Telegram")
        XCTAssertTrue(legacyCLI.requiresExternalImport)
        XCTAssertEqual(legacyCLI.sourceDisplayLabel, "CLI")
    }

    func testWebUISourceOverridesStaleCLIFlag() {
        let imported = SessionSummary(
            sessionId: "imported",
            isCliSession: true,
            rawSource: "telegram",
            sessionSource: "webui",
            sourceLabel: "WebUI"
        )

        XCTAssertFalse(imported.requiresExternalImport)
        XCTAssertNil(imported.sourceDisplayLabel)
    }

    func testChatComposerReadOnlyMessageUsesServerAndOfflineState() {
        XCTAssertEqual(
            ChatView.composerReadOnlyMessage(
                for: SessionSummary(sessionId: "read-only", readOnly: true),
                isViewingCachedData: false
            ),
            "Read-only"
        )
        XCTAssertEqual(
            ChatView.composerReadOnlyMessage(
                for: SessionSummary(sessionId: "offline"),
                isViewingCachedData: true
            ),
            "Reconnect to send messages."
        )
        XCTAssertNil(
            ChatView.composerReadOnlyMessage(
                for: SessionSummary(sessionId: "writable"),
                isViewingCachedData: false
            )
        )
    }

    /// A row without a `session_id` gets the same identity every time it decodes, so a list
    /// reload never re-identifies it.
    func testSessionSummaryFallbackIDIsDeterministicWithoutSessionID() throws {
        let json = Data(#"{"title": "Older Session", "created_at": 1770000000}"#.utf8)

        XCTAssertEqual(try decode(SessionSummary.self, json).id, try decode(SessionSummary.self, json).id)
    }

    func testSessionDetailFallbackIDIsDeterministicWithoutSessionID() throws {
        let json = Data(#"{"title": "Legacy Session", "updated_at": 1770000100}"#.utf8)

        XCTAssertEqual(try decode(SessionDetail.self, json).id, try decode(SessionDetail.self, json).id)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: json)
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
}

final class SectionVisibilitySettingsTests: XCTestCase {
    private let allKeys = [
        SectionVisibilitySettings.tasksKey,
        SectionVisibilitySettings.kanbanKey,
        SectionVisibilitySettings.skillsKey,
        SectionVisibilitySettings.memoryKey,
        SectionVisibilitySettings.insightsKey,
        SectionVisibilitySettings.activeProfileKey,
        SectionVisibilitySettings.projectsKey,
        SectionVisibilitySettings.chatFilesKey,
        SectionVisibilitySettings.chatGitKey
    ]

    func testKeysAreDistinctSoOneToggleCannotMoveAnother() {
        XCTAssertEqual(Set(allKeys).count, allKeys.count)
    }
}

final class SidebarSectionVisibilityTests: XCTestCase {
    func testUtilityLinkRowDropsOnlyWhenEveryLinkIsHidden() {
        var visibility = SidebarSectionVisibility.showAll
        visibility.tasks = false
        visibility.kanban = false
        visibility.skills = false
        visibility.memory = false
        visibility.insights = false

        XCTAssertTrue(visibility.showsAnyUtilityLink, "the Bots row keeps the row alive while Bot Mode is on")
        visibility.bots = false
        XCTAssertFalse(visibility.showsAnyUtilityLink)
    }

    func testProfileAndProjectRowsDoNotAffectTheUtilityLinkRow() {
        var visibility = SidebarSectionVisibility.showAll
        visibility.activeProfile = false
        visibility.projects = false

        XCTAssertTrue(visibility.showsAnyUtilityLink)
    }
}
