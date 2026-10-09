import SwiftUI
import HermexWatchRoot
import WatchShared

// MARK: - Kanban

/// The board the iPhone is browsing. Status chips keep their counts at zero,
/// and the wrist can switch boards, search, create a card, run the dispatcher,
/// and filter. Comments, edits, blocking, and bulk selection stay on iPhone.
struct WatchKanbanListView: View {
    @Bindable var model: WatchRootModel
    @State private var chrome = WatchKanbanBoardChrome.placeholder
    @State private var cards: [WatchKanbanCard] = []
    @State private var selectedStatus = "triage"
    @State private var searchText = ""
    @State private var includeArchived = false
    @State private var onlyMine = false
    @State private var boardSlug: String?
    @State private var phase: WatchGlancePhase = .loading
    @State private var didLoad = false
    @State private var route: WatchKanbanRoute?

    var body: some View {
        List {
            if didLoad {
                boardRow
                actionRow
                statusRow
                searchRow
            }
            if case .failed(let message) = phase {
                WatchGlanceStatusRows(
                    phase: .failed(message),
                    isEmpty: false,
                    emptyTitle: "",
                    emptySymbol: "square.grid.2x2",
                    retry: reload
                )
            }
            if phase == .loading, !didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .listRowBackground(Color.clear)
            } else if didLoad, visibleCards.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No Cards in this Status")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Choose another Status or refresh the Board.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(visibleCards) { card in
                NavigationLink {
                    WatchKanbanCardView(model: model, card: card, movePolicy: chrome.resolvedMovePolicy) {
                        await reload()
                    }
                } label: {
                    cardRow(card)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if WatchKanbanStatus.moveDestinations(from: card.status, policy: chrome.resolvedMovePolicy).contains("done"),
                       !WatchKanbanStatus.needsRunningExitConfirmation(from: card.status) {
                        Button {
                            Task { await move(card, to: "done") }
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                        .tint(.green)
                        .disabled(!model.canMutate)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if let next = WatchKanbanStatus.moveDestinations(from: card.status, policy: chrome.resolvedMovePolicy).first(where: { $0 != "done" }),
                       !WatchKanbanStatus.needsRunningExitConfirmation(from: card.status) {
                        Button {
                            Task { await move(card, to: next) }
                        } label: {
                            Label(WatchKanbanStatus.title(next), systemImage: "arrow.right")
                        }
                        .tint(.blue)
                        .disabled(!model.canMutate)
                    }
                }
            }
        }
        .navigationTitle("Kanban")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { route in
            switch route {
            case .boards:
                WatchKanbanBoardPicker(boards: chrome.boards, currentSlug: chrome.slug) { slug in
                    boardSlug = slug
                    await reload()
                }
            case .create:
                WatchKanbanCreateCardView(model: model, boardSlug: chrome.slug, movePolicy: chrome.resolvedMovePolicy) { status in
                    selectedStatus = status
                    await reload()
                }
            case .dispatch:
                WatchKanbanDispatchView(model: model, boardSlug: chrome.slug)
            case .filters:
                WatchKanbanFiltersView(onlyMine: $onlyMine, includeArchived: $includeArchived)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: onlyMine) { _, _ in
            guard didLoad else { return }
            Task { await reload() }
        }
        .onChange(of: includeArchived) { _, _ in
            guard didLoad else { return }
            Task { await reload() }
        }
    }

    private var boardRow: some View {
        Button {
            route = .boards
        } label: {
            HStack(spacing: 4) {
                Text(boardTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kanban.board")
        .accessibilityLabel("Board, \(boardTitle)")
        .accessibilityHint("Switches the board. Managing boards stays on iPhone.")
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            routeButton(systemImage: "plus", route: .create, identifier: "kanban.newCard", label: "New Card", hint: "Creates a card on this board.")
            routeButton(systemImage: "bolt.fill", route: .dispatch, identifier: "kanban.dispatcher", label: "Dispatcher", hint: "Previews or runs the dispatcher.")
            routeButton(systemImage: "ellipsis", route: .filters, identifier: "kanban.more", label: "More", hint: "Filters this board.")
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
    }

    /// Two rows, not a horizontal scroller. A scroller inside a watch list
    /// collapses and the chips draw on top of the buttons.
    private var statusRow: some View {
        let columns = chrome.columns
        let split = max(1, (columns.count + 1) / 2)
        return VStack(alignment: .leading, spacing: 4) {
            chipLine(Array(columns.prefix(split)))
            if columns.count > split {
                chipLine(Array(columns.dropFirst(split)))
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)
    }

    private func chipLine(_ statuses: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(statuses, id: \.self) { status in
                let count = statusCount(status)
                let title = WatchKanbanStatus.title(status)
                Button {
                    selectedStatus = status
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(selectedStatus == status ? Color.white : WatchKanbanPresentation.tint(status))
                            .frame(width: 6, height: 6)
                        Text("\(title) \(count)")
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .tint(selectedStatus == status ? WatchKanbanPresentation.tint(status) : .gray)
                .accessibilityIdentifier("kanban.status.\(status)")
                .accessibilityLabel("\(title), \(count)")
            }
        }
    }

    /// A list `TextField` does not open the watch keyboard. `TextFieldLink` does,
    /// and it stays in the row instead of covering the buttons the way
    /// `.searchable` did.
    private var searchRow: some View {
        HStack(spacing: 6) {
            TextFieldLink(prompt: Text("Search Cards")) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text(searchText.isEmpty ? "Search Cards" : searchText)
                        .lineLimit(1)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            } onSubmit: { text in
                searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .accessibilityIdentifier("kanban.search")
            .accessibilityLabel(searchText.isEmpty ? "Search Cards" : "Search Cards, \(searchText)")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var boardTitle: String {
        let name = chrome.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Board" : name
    }

    private var visibleCards: [WatchKanbanCard] {
        cards.filter { $0.status == selectedStatus && matchesSearch($0) }
    }

    private func statusCount(_ status: String) -> Int {
        cards.filter { $0.status == status && matchesSearch($0) }.count
    }

    private func matchesSearch(_ card: WatchKanbanCard) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields = [card.title, card.body, card.id, card.assignee, card.tenant, card.skills?.joined(separator: " ")]
        return fields.compactMap { $0 }.contains { $0.localizedStandardContains(query) }
    }

    private func routeButton(
        systemImage: String,
        route: WatchKanbanRoute,
        identifier: String,
        label: String,
        hint: String
    ) -> some View {
        Button {
            self.route = route
        } label: {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func cardRow(_ card: WatchKanbanCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let priority = card.priority {
                    Text("P\(priority)")
                        .font(.caption2.monospaced().weight(.semibold))
                }
                Text(card.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let age = card.ageLabel {
                    Text(age)
                        .font(.caption2.monospaced())
                        .foregroundStyle(WatchKanbanPresentation.ageTint(card.staleness))
                }
            }
            Text(WatchTextBreaking.breakable(card.title))
                .font(.footnote)
                .lineLimit(2)
            if let body = card.body {
                Text(body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let meta = WatchKanbanPresentation.meta(card) {
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the card and where it can move.")
    }

    private func move(_ card: WatchKanbanCard, to status: String) async {
        guard await model.moveKanbanCard(cardID: card.id, status: status) else {
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        await reload()
    }

    private func reload() async {
        if !didLoad { phase = .loading }
        let slug = boardSlug ?? (chrome.slug.isEmpty ? nil : chrome.slug)
        guard let loaded = await model.loadKanbanBoard(slug: slug, includeArchived: includeArchived, onlyMine: onlyMine) else {
            phase = .after(model)
            return
        }
        chrome = loaded.chrome
        cards = loaded.cards
        if !chrome.columns.contains(selectedStatus) {
            selectedStatus = chrome.columns.contains("triage") ? "triage" : (chrome.columns.first ?? "triage")
        }
        phase = .loaded
        didLoad = true
    }
}

private enum WatchKanbanRoute: Hashable {
    case boards
    case create
    case dispatch
    case filters
}

private struct WatchKanbanBoardPicker: View {
    @Environment(\.dismiss) private var dismiss
    let boards: [WatchKanbanBoardChrome.Choice]
    let currentSlug: String
    let select: (String) async -> Void

    var body: some View {
        List {
            Section {
                if boards.isEmpty {
                    Text("No other boards")
                        .foregroundStyle(.secondary)
                }
                ForEach(boards, id: \.slug) { board in
                    Button {
                        Task {
                            await select(board.slug)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(board.name).lineLimit(1)
                            Spacer()
                            if board.slug == currentSlug {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel(board.slug == currentSlug ? "\(board.name), current board" : board.name)
                }
            } footer: {
                Text("Managing boards stays on iPhone.")
            }
        }
        .navigationTitle("Boards")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchKanbanCreateCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WatchRootModel
    let boardSlug: String
    var movePolicy: WatchKanbanMovePolicy = .webui
    let onCreate: (String) async -> Void
    @State private var title = ""
    @State private var status = "triage"
    @State private var saving = false
    @State private var actionError: String?

    private var statuses: [String] { WatchKanbanStatus.createDestinations(policy: movePolicy) }

    var body: some View {
        List {
            if let actionError {
                WatchActionErrorRow(message: actionError)
            }
            TextField("Title", text: $title)
            Picker("Status", selection: $status) {
                ForEach(statuses, id: \.self) { column in
                    Text(WatchKanbanStatus.title(column)).tag(column)
                }
            }
            Button {
                Task { await create() }
            } label: {
                if saving {
                    ProgressView()
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || !model.canMutate || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || boardSlug.isEmpty)
        }
        .navigationTitle("New Card")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func create() async {
        saving = true
        actionError = nil
        defer { saving = false }
        let created = await model.createKanbanCard(boardSlug: boardSlug, title: title, status: status)
        guard created else {
            actionError = model.errorCopy ?? "Couldn’t create that card."
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        await onCreate(status)
        dismiss()
    }
}

private struct WatchKanbanDispatchView: View {
    @Bindable var model: WatchRootModel
    let boardSlug: String
    @State private var summary: String?
    @State private var busy = false
    @State private var confirmRun = false
    @State private var actionError: String?

    var body: some View {
        List {
            if let actionError {
                WatchActionErrorRow(message: actionError)
            }
            Button {
                Task { await run(dryRun: true) }
            } label: {
                Text("Preview")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !model.canMutate || boardSlug.isEmpty)
            .accessibilityHint("Shows what the dispatcher would do. Nothing starts.")
            Button {
                confirmRun = true
            } label: {
                Text("Run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy || !model.canMutate || boardSlug.isEmpty)
            .accessibilityHint("Starts ready cards on this board. Up to 8.")
            if let summary {
                Text(summary)
                    .font(.footnote)
            }
        }
        .navigationTitle("Dispatcher")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Run the dispatcher?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Run") { Task { await run(dryRun: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts ready cards on this board. Up to 8.")
        }
    }

    private func run(dryRun: Bool) async {
        busy = true
        actionError = nil
        defer { busy = false }
        guard let result = await model.dispatchKanban(boardSlug: boardSlug, dryRun: dryRun) else {
            actionError = model.errorCopy ?? "Couldn’t run the dispatcher."
            WatchHaptics.play(.failure)
            return
        }
        summary = result
        WatchHaptics.play(.success)
    }
}

private struct WatchKanbanFiltersView: View {
    @Binding var onlyMine: Bool
    @Binding var includeArchived: Bool

    var body: some View {
        List {
            Section {
                Toggle("Only Mine", isOn: $onlyMine)
                Toggle(isOn: $includeArchived) {
                    Text("Include archived")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityLabel("Include archived cards")
            } footer: {
                Text("Selecting cards stays on iPhone.")
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum WatchKanbanPresentation {
    /// Same status colours as the iPhone board.
    static func tint(_ status: String) -> Color {
        switch status {
        case "triage": return .gray
        case "todo": return .blue
        case "scheduled": return .indigo
        case "ready": return .mint
        case "running": return .orange
        case "blocked": return .red
        case "review": return .yellow
        case "done": return .green
        case "archived": return .secondary
        default: return .purple
        }
    }

    static func ageTint(_ staleness: WatchKanbanCard.Staleness) -> Color {
        switch staleness {
        case .none: return .secondary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// The facts under the title on the iPhone card: who has it, which tenant,
    /// and how many comments and links. Priority and age sit on their own line.
    static func meta(_ card: WatchKanbanCard) -> String? {
        var parts = [card.assignee ?? "Unassigned"]
        if let tenant = card.tenant { parts.append(tenant) }
        if let comments = card.commentCount, comments > 0 {
            parts.append(comments == 1 ? "1 comment" : "\(comments) comments")
        }
        if let links = card.linkCount, links > 0 {
            parts.append(links == 1 ? "1 link" : "\(links) links")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Card detail

struct WatchKanbanCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WatchRootModel
    var movePolicy: WatchKanbanMovePolicy = .webui
    let onChange: () async -> Void
    @State private var card: WatchKanbanCard
    @State private var moving: String?
    @State private var actionError: String?
    @State private var pendingRunningExit: String?

    init(
        model: WatchRootModel,
        card: WatchKanbanCard,
        movePolicy: WatchKanbanMovePolicy = .webui,
        onChange: @escaping () async -> Void
    ) {
        self.model = model
        self.movePolicy = movePolicy
        self.onChange = onChange
        _card = State(initialValue: card)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(WatchTextBreaking.breakable(card.title))
                        .font(.headline)
                    WatchStatusBadge(
                        text: WatchKanbanStatus.title(card.status),
                        tint: WatchKanbanPresentation.tint(card.status)
                    )
                }
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }

            // The action this screen exists for comes before the reference
            // detail. Destinations share one row-pair so a 40mm watch shows
            // every move without a scroll.
            let destinations = WatchKanbanStatus.moveDestinations(from: card.status, policy: movePolicy)
            if !destinations.isEmpty {
                Section {
                    if let actionError {
                        WatchActionErrorRow(message: actionError)
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(stride(from: 0, to: destinations.count, by: 2)), id: \.self) { index in
                            HStack(spacing: 6) {
                                moveButton(destinations[index])
                                if index + 1 < destinations.count {
                                    moveButton(destinations[index + 1])
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                } header: {
                    Text("Move to")
                }
            }

            Section {
                WatchFactRow(title: "Card", systemImage: "number") {
                    Text(card.id).lineLimit(1).font(.caption2.monospaced())
                }
                WatchFactRow(title: "Profile", systemImage: "person.crop.circle") {
                    Text(card.assignee ?? "Unassigned").lineLimit(1)
                }
                if let tenant = card.tenant {
                    WatchFactRow(title: "Tenant", systemImage: "building.2") {
                        Text(tenant).lineLimit(1)
                    }
                }
                if let priority = card.priority {
                    WatchFactRow(title: "Priority", systemImage: "flag") {
                        Text("P\(priority)")
                    }
                }
                if let age = card.ageLabel {
                    WatchFactRow(title: "Age", systemImage: "clock") {
                        Text(age).foregroundStyle(WatchKanbanPresentation.ageTint(card.staleness))
                    }
                }
                if let comments = card.commentCount, comments > 0 {
                    WatchFactRow(title: "Comments", systemImage: "bubble.left") {
                        Text("\(comments)")
                    }
                }
                if let links = card.linkCount, links > 0 {
                    WatchFactRow(title: "Links", systemImage: "link") {
                        Text("\(links)")
                    }
                }
                if let skills = card.skills, !skills.isEmpty {
                    WatchFactRow(title: "Skills", systemImage: "wrench.and.screwdriver") {
                        Text(skills.joined(separator: ", ")).lineLimit(2)
                    }
                }
                if let body = card.body {
                    WatchMarkdownText(text: body)
                        .listRowBackground(Color.clear)
                }
            } footer: {
                Text("Comments, edits and blocking stay on iPhone.")
            }
        }
        .navigationTitle("Card")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Leave Running?",
            isPresented: Binding(
                get: { pendingRunningExit != nil },
                set: { if !$0 { pendingRunningExit = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                let status = pendingRunningExit
                pendingRunningExit = nil
                if let status { Task { await move(to: status) } }
            }
            Button("Cancel", role: .cancel) { pendingRunningExit = nil }
        } message: {
            Text("Leaving Running may clear the card’s claim and worker state.")
        }
    }

    private func moveButton(_ status: String) -> some View {
        Button {
            if WatchKanbanStatus.needsRunningExitConfirmation(from: card.status) {
                pendingRunningExit = status
            } else {
                Task { await move(to: status) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(status == "done" ? "Mark Done" : WatchKanbanStatus.title(status))
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if moving == status {
                    ProgressView()
                        .frame(width: 16, height: 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(moving != nil || !model.canMutate)
        .accessibilityIdentifier("kanban.move.\(status)")
        .accessibilityHint(status == "done" ? "Completes this card." : "Moves this card to \(WatchKanbanStatus.title(status)).")
    }

    private func move(to status: String) async {
        moving = status
        actionError = nil
        defer { moving = nil }
        guard await model.moveKanbanCard(cardID: card.id, status: status) else {
            actionError = "Couldn’t move that card."
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        await onChange()
        // A Hermes host can land a Ready request in To Do or Review. The list
        // reload is the status that actually stuck, so leave this card.
        if movePolicy == .hermes {
            dismiss()
        } else {
            card = card.withStatus(status)
        }
    }
}
