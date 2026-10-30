import XCTest
@testable import HermesMobile

/// The quick switcher's pure model (#1415): recents order, the shared multi-word
/// matcher, destination availability, and the identity a pick routes with.
@MainActor final class QuickSwitcherModelTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connectionID = UUID()

    private func session(_ id: String, title: String, profile: String? = "default",
                         lastMessageAt: Double, workspace: String? = nil) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "\(id)",
              "title": "\(title)",
              "profile": "\(profile ?? "")",
              "last_message_at": \(lastMessageAt)\(workspace.map { ",\n  \"workspace\": \"\($0)\"" } ?? "")
            }
            """.utf8)
        )
    }

    private func bot(_ id: String, displayName: String? = nil, title: String? = nil,
                     sectionName: String? = nil, hidden: Bool = false) -> BotProfile {
        var look: [String: BotJSON] = [:]
        if let title { look["title"] = .string(title) }
        if let sectionName { look["sectionName"] = .string(sectionName) }
        if hidden { look["hidden"] = .bool(true) }
        var row: [String: BotJSON] = [
            "name": .string(id),
            "ui_meta": .object(["hermes-bots": .object(look)])
        ]
        if let displayName { row["display_name"] = .string(displayName) }
        return BotProfile(.object(row))!
    }

    // MARK: Recents

    func testAnEmptyQueryOrdersRecentsNewestFirstWithTheOpenChatLast() throws {
        let rows = [
            try session("a", title: "Old", lastMessageAt: 100),
            try session("b", title: "Newest", lastMessageAt: 300),
            try session("c", title: "Open", lastMessageAt: 200)
        ]
        let items = QuickSwitcherModel.items(sessions: rows, bots: [], destinations: [], query: "", openSessionKey: "c")
        XCTAssertEqual(items.map(\.title), ["Newest", "Old", "Open"])
    }

    func testAnEmptyQueryListsTheRosterAndDestinationsAfterTheRecents() throws {
        let rows = [try session("a", title: "Only", lastMessageAt: 1)]
        let items = QuickSwitcherModel.items(
            sessions: rows, bots: [bot("triage", displayName: "Triage")],
            destinations: [.tasks, .settings], query: "", openSessionKey: nil
        )
        XCTAssertEqual(items.map(\.title), ["Only", "Triage", "Tasks", "Settings"])
    }

    // MARK: Filtering

    func testAMultiWordQueryMatchesAsTheListSearchDoes() throws {
        let rows = [try session("a", title: "Fix login flow", lastMessageAt: 1, workspace: "titan")]
        let terms = { query in
            SessionListViewModel.normalizedSearchQuery(query).split(whereSeparator: \.isWhitespace)
        }
        for query in ["login titan", "titan login", "LOGIN", "fix"] {
            let items = QuickSwitcherModel.items(sessions: rows, bots: [], destinations: [], query: query, openSessionKey: nil)
            XCTAssertEqual(items.count, 1, query)
            XCTAssertTrue(SessionListViewModel.matches(searchTerms: terms(query), in: "fix login flow titan"), query)
        }
        XCTAssertTrue(QuickSwitcherModel.items(sessions: rows, bots: [], destinations: [], query: "login absent", openSessionKey: nil).isEmpty)
        XCTAssertTrue(QuickSwitcherModel.items(sessions: rows, bots: [], destinations: [], query: "titanic", openSessionKey: nil).isEmpty)
    }

    func testAQueryFiltersBotsByRosterFieldsAndDestinationsByTitle() {
        let bots = [bot("inbox-triage", title: "Triage", sectionName: "Support")]
        XCTAssertTrue(QuickSwitcherModel.items(sessions: [], bots: bots, destinations: [.tasks], query: "triage", openSessionKey: nil).count == 1)
        XCTAssertTrue(QuickSwitcherModel.items(sessions: [], bots: bots, destinations: [.tasks], query: "support", openSessionKey: nil).count == 1)
        XCTAssertTrue(QuickSwitcherModel.items(sessions: [], bots: bots, destinations: [.tasks], query: "task", openSessionKey: nil).count == 1)
        XCTAssertTrue(QuickSwitcherModel.items(sessions: [], bots: bots, destinations: [.tasks], query: "kanban", openSessionKey: nil).isEmpty)
    }

    // MARK: Destinations

    func testDestinationsFollowTheirVisibilityWithSettingsAlwaysLast() {
        XCTAssertEqual(
            QuickSwitcherModel.destinations(showsTasks: true, showsKanban: false, showsSkills: true,
                                            showsMemory: false, showsInsights: true, showsArchived: true),
            [.tasks, .skills, .insights, .archived, .settings]
        )
        XCTAssertEqual(
            QuickSwitcherModel.destinations(showsTasks: false, showsKanban: false, showsSkills: false,
                                            showsMemory: false, showsInsights: false, showsArchived: false),
            [.settings]
        )
    }
}
