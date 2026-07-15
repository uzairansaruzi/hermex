#if DEBUG
import Observation
import SwiftUI

// PROTOTYPE — throwaway, in-memory domain state for issue 142.
// Three interaction models consume the same state so the maintainer can compare
// navigation and control placement rather than three different data sets.

enum KanbanPrototypeVariant: String, CaseIterable, Identifiable {
    case statusFocus
    case swipeableBoard
    case commandCenter

    var id: Self { self }

    var shortName: String {
        switch self {
        case .statusFocus: "A — Status Focus"
        case .swipeableBoard: "B — Swipeable Board"
        case .commandCenter: "C — Command Center"
        }
    }

    var question: String {
        switch self {
        case .statusFocus: "Can one status at a time make a dense Board calm and legible?"
        case .swipeableBoard: "Is the spatial Board worth horizontal navigation on iPhone?"
        case .commandCenter: "Does search-first discovery beat preserving Board geography?"
        }
    }

    mutating func advance(by offset: Int) {
        let variants = Self.allCases
        let current = variants.firstIndex(of: self) ?? 0
        let next = (current + offset + variants.count) % variants.count
        self = variants[next]
    }
}

enum KanbanPrototypeScenario: String, CaseIterable, Identifiable {
    case dense
    case empty
    case loading
    case error

    var id: Self { self }

    var label: String {
        switch self {
        case .dense: "Dense Board"
        case .empty: "Empty Board"
        case .loading: "Loading"
        case .error: "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .dense: "rectangle.3.group"
        case .empty: "rectangle.dashed"
        case .loading: "hourglass"
        case .error: "exclamationmark.triangle"
        }
    }
}

enum KanbanPrototypeStatus: String, CaseIterable, Identifiable, Hashable {
    case triage
    case todo
    case ready
    case running
    case blocked
    case done
    case archived

    var id: Self { self }

    var label: String {
        switch self {
        case .triage: "Triage"
        case .todo: "To Do"
        case .ready: "Ready"
        case .running: "Running"
        case .blocked: "Blocked"
        case .done: "Done"
        case .archived: "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .triage: "tray"
        case .todo: "list.bullet"
        case .ready: "checkmark.circle"
        case .running: "bolt.fill"
        case .blocked: "hand.raised.fill"
        case .done: "checkmark.seal.fill"
        case .archived: "archivebox.fill"
        }
    }

    var color: Color {
        switch self {
        case .triage: .gray
        case .todo: .indigo
        case .ready: .mint
        case .running: .blue
        case .blocked: .orange
        case .done: .green
        case .archived: .secondary
        }
    }

    static var boardCases: [Self] { allCases.filter { $0 != .archived } }
    static var directlyMovableCases: [Self] { allCases.filter { $0 != .running } }
}

struct KanbanPrototypeCard: Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: String
    var status: KanbanPrototypeStatus
    var assignedProfile: String?
    var priority: Int
    var prerequisiteCount: Int
    var dependentCount: Int
    var commentCount: Int
    var age: String

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        status: KanbanPrototypeStatus,
        assignedProfile: String? = nil,
        priority: Int = 0,
        prerequisiteCount: Int = 0,
        dependentCount: Int = 0,
        commentCount: Int = 0,
        age: String = "just now"
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.assignedProfile = assignedProfile
        self.priority = priority
        self.prerequisiteCount = prerequisiteCount
        self.dependentCount = dependentCount
        self.commentCount = commentCount
        self.age = age
    }
}

@MainActor
@Observable final class KanbanPrototypeStore {
    var cards: [KanbanPrototypeCard] = KanbanPrototypeStore.fixtureCards
    var currentBoard = "Hermex Roadmap"
    var selectedStatus: KanbanPrototypeStatus = .ready
    var selectedCardIDs: Set<UUID> = []
    var selectedProfile: String?
    var selectedStatusFilter: KanbanPrototypeStatus?
    var searchText = ""
    var feedbackMessage: String?

    let boards = ["Hermex Roadmap", "Infrastructure", "Release 1.0"]
    let profiles = ["Builder", "Researcher", "Reviewer", "Release Manager"]

    var filteredCards: [KanbanPrototypeCard] {
        cards.filter { card in
            let matchesSearch = searchText.isEmpty
                || card.title.localizedCaseInsensitiveContains(searchText)
                || card.body.localizedCaseInsensitiveContains(searchText)
            let matchesProfile = selectedProfile == nil || card.assignedProfile == selectedProfile
            let matchesStatus = selectedStatusFilter == nil || card.status == selectedStatusFilter
            return matchesSearch && matchesProfile && matchesStatus
        }
    }

    var activeFilterCount: Int {
        (selectedProfile == nil ? 0 : 1)
            + (selectedStatusFilter == nil ? 0 : 1)
            + (searchText.isEmpty ? 0 : 1)
    }

    func cards(in status: KanbanPrototypeStatus) -> [KanbanPrototypeCard] {
        filteredCards
            .filter { $0.status == status }
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority { return lhs.title < rhs.title }
                return lhs.priority > rhs.priority
            }
    }

    func count(in status: KanbanPrototypeStatus) -> Int {
        cards.filter { $0.status == status }.count
    }

    func toggleSelection(of card: KanbanPrototypeCard) {
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    func clearSelection() {
        selectedCardIDs.removeAll()
    }

    func move(cardID: UUID, to status: KanbanPrototypeStatus) {
        guard status != .running, let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].status = status
        feedbackMessage = "Moved “\(cards[index].title)” to \(status.label)."
    }

    func bulkMove(to status: KanbanPrototypeStatus) {
        guard status != .running else { return }
        for index in cards.indices where selectedCardIDs.contains(cards[index].id) {
            cards[index].status = status
        }
        feedbackMessage = "Changed \(selectedCardIDs.count) Cards to \(status.label)."
        clearSelection()
    }

    func bulkAssign(profile: String?) {
        for index in cards.indices where selectedCardIDs.contains(cards[index].id) {
            cards[index].assignedProfile = profile
        }
        feedbackMessage = profile.map { "Assigned \(selectedCardIDs.count) Cards to \($0)." }
            ?? "Unassigned \(selectedCardIDs.count) Cards."
        clearSelection()
    }

    func archiveSelection() {
        bulkMove(to: .archived)
    }

    func save(_ card: KanbanPrototypeCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
            feedbackMessage = "Saved “\(card.title)”."
        } else {
            cards.append(card)
            feedbackMessage = "Created “\(card.title)”."
        }
    }

    func reset() {
        cards = Self.fixtureCards
        selectedStatus = .ready
        selectedCardIDs.removeAll()
        selectedProfile = nil
        selectedStatusFilter = nil
        searchText = ""
        feedbackMessage = "Prototype data reset."
    }

    private static let fixtureCards: [KanbanPrototypeCard] = [
        .init(title: "Clarify offline cache policy", body: "Decide which Kanban reads remain visible after the server disconnects.", status: .triage, assignedProfile: "Researcher", priority: 3, commentCount: 4, age: "18m"),
        .init(title: "Audit Spanish terminology", body: "Check Card, Board, Dispatcher, and dependency copy in context.", status: .triage, priority: 1, age: "2h"),
        .init(title: "Draft compatibility notice", body: "Persistent but quiet disclosure for partially compatible servers.", status: .triage, assignedProfile: "Reviewer", priority: 2, age: "1d"),
        .init(title: "Model tolerant Board decoding", body: "Keep every upstream property optional and validate semantic identity after decoding.", status: .todo, assignedProfile: "Builder", priority: 4, prerequisiteCount: 1, commentCount: 2, age: "3h"),
        .init(title: "Define ambiguous mutation recovery", body: "Refetch canonical state and preserve an explicit uncertain outcome.", status: .todo, assignedProfile: "Researcher", priority: 5, dependentCount: 2, age: "6h"),
        .init(title: "Localize dispatcher safety copy", body: "Explain that Run Dispatcher may launch workers and consume API budget.", status: .todo, assignedProfile: "Release Manager", priority: 3, age: "8h"),
        .init(title: "Build Board capability handshake", body: "Probe config, Boards, and current Board without issuing mutations.", status: .ready, assignedProfile: "Builder", priority: 8, prerequisiteCount: 2, commentCount: 5, age: "12m"),
        .init(title: "Add per-capability failure state", body: "Disable only incompatible mutations while keeping browsing available.", status: .ready, assignedProfile: "Builder", priority: 7, age: "34m"),
        .init(title: "Seed isolated integration server", body: "Create deterministic Boards and Cards without touching real operator data.", status: .ready, assignedProfile: "Release Manager", priority: 6, prerequisiteCount: 1, age: "1h"),
        .init(title: "Exercise partial bulk results", body: "Show successful and failed Cards separately after a bulk mutation.", status: .ready, assignedProfile: "Reviewer", priority: 5, commentCount: 3, age: "4h"),
        .init(title: "Stream Board events", body: "Reconnect SSE by Board and fall back to event polling after repeated failures.", status: .running, assignedProfile: "Builder", priority: 9, age: "7m"),
        .init(title: "Write Card detail contract tests", body: "Cover comments, dependencies, runs, and truncated worker logs.", status: .running, assignedProfile: "Reviewer", priority: 6, age: "28m"),
        .init(title: "Confirm archive recovery story", body: "Hermex cannot restore an archived Board in-app.", status: .blocked, assignedProfile: "Researcher", priority: 7, prerequisiteCount: 1, commentCount: 8, age: "2d"),
        .init(title: "Resolve server-global Board switching", body: "Make shared-state consequences visible without making routine navigation alarming.", status: .blocked, assignedProfile: "Reviewer", priority: 6, prerequisiteCount: 2, age: "3d"),
        .init(title: "Inventory upstream Kanban contract", body: "Verified live and pinned route surface with exact response shapes.", status: .done, assignedProfile: "Researcher", priority: 8, dependentCount: 4, commentCount: 7, age: "1d"),
        .init(title: "Choose domain vocabulary", body: "Locked Board, Card, Status, Profile, and Dispatcher language.", status: .done, assignedProfile: "Reviewer", priority: 7, dependentCount: 3, age: "9h"),
        .init(title: "Verify authenticated wire responses", body: "Read-only probes match the live and pinned payload builders.", status: .done, assignedProfile: "Release Manager", priority: 6, age: "5h"),
        .init(title: "Old prototype notes", body: "Archived design exploration retained for reference.", status: .archived, assignedProfile: "Builder", age: "12d")
    ]
}
#endif
