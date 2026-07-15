#if DEBUG
import SwiftUI

/// PROTOTYPE — issue 142 only. Three native iPhone Kanban interaction models,
/// switchable from the floating bottom control. Launch with `--kanban-prototype`.
struct KanbanPrototypeView: View {
    @State private var store = KanbanPrototypeStore()
    @State private var variant: KanbanPrototypeVariant = .statusFocus
    @State private var scenario: KanbanPrototypeScenario = .dense
    @State private var presentedCard: KanbanPrototypeCard?
    @State private var isCreatingCard = false
    @State private var isShowingFilters = false
    @State private var isShowingBulkActions = false
    @State private var isShowingDispatcher = false
    @State private var isShowingBoards = false

    var body: some View {
        NavigationStack {
            prototypeContent
                .navigationTitle("Kanban Prototype")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { prototypeToolbar }
                .safeAreaInset(edge: .bottom) { variantSwitcher }
        }
        .sheet(item: $presentedCard) { card in
            KanbanPrototypeCardEditor(card: card, profiles: store.profiles) { store.save($0) }
        }
        .sheet(isPresented: $isCreatingCard) {
            KanbanPrototypeCardEditor(
                card: .init(title: "", body: "", status: .triage),
                profiles: store.profiles,
                isNew: true
            ) { store.save($0) }
        }
        .sheet(isPresented: $isShowingFilters) {
            KanbanPrototypeFiltersSheet(store: store)
        }
        .sheet(isPresented: $isShowingBulkActions) {
            KanbanPrototypeBulkActionsSheet(store: store)
        }
        .sheet(isPresented: $isShowingDispatcher) {
            KanbanPrototypeDispatcherSheet(store: store)
        }
        .sheet(isPresented: $isShowingBoards) {
            KanbanPrototypeBoardsSheet(store: store)
        }
        .overlay(alignment: .top) { feedbackBanner }
    }

    @ViewBuilder
    private var prototypeContent: some View {
        switch scenario {
        case .dense:
            variantContent
        case .empty:
            ContentUnavailableView {
                Label("No Cards", systemImage: "rectangle.3.group")
            } description: {
                Text("This Board is ready for its first Card.")
            } actions: {
                Button("New Card") { isCreatingCard = true }
                    .buttonStyle(.borderedProminent)
            }
        case .loading:
            VStack {
                ProgressView("Loading \(store.currentBoard)…")
                Text("Checking this server’s Kanban capabilities")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            ContentUnavailableView {
                Label("Kanban Is Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This server returned an incompatible Board response. No Card actions are available.")
            } actions: {
                Button("Try Again") { scenario = .dense }
                Button("Troubleshooting") { store.feedbackMessage = "Would open concise compatibility guidance." }
            }
        }
    }

    @ViewBuilder
    private var variantContent: some View {
        switch variant {
        case .statusFocus:
            KanbanStatusFocusPrototype(
                store: store,
                openCard: { presentedCard = $0 },
                newCard: { isCreatingCard = true },
                showFilters: { isShowingFilters = true },
                showBulkActions: { isShowingBulkActions = true },
                showDispatcher: { isShowingDispatcher = true },
                showBoards: { isShowingBoards = true }
            )
        case .swipeableBoard:
            KanbanSwipeableBoardPrototype(
                store: store,
                openCard: { presentedCard = $0 },
                newCard: { isCreatingCard = true },
                showFilters: { isShowingFilters = true },
                showBulkActions: { isShowingBulkActions = true },
                showDispatcher: { isShowingDispatcher = true },
                showBoards: { isShowingBoards = true }
            )
        case .commandCenter:
            KanbanCommandCenterPrototype(
                store: store,
                openCard: { presentedCard = $0 },
                newCard: { isCreatingCard = true },
                showFilters: { isShowingFilters = true },
                showBulkActions: { isShowingBulkActions = true },
                showDispatcher: { isShowingDispatcher = true },
                showBoards: { isShowingBoards = true }
            )
        }
    }

    @ToolbarContentBuilder
    private var prototypeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Scenario", selection: $scenario) {
                    ForEach(KanbanPrototypeScenario.allCases) { scenario in
                        Label(scenario.label, systemImage: scenario.systemImage).tag(scenario)
                    }
                }
                Divider()
                Button("Reset Prototype Data", systemImage: "arrow.counterclockwise") { store.reset() }
            } label: {
                Label("Prototype Scenario", systemImage: scenario.systemImage)
            }
            .accessibilityLabel("Prototype scenario: \(scenario.label)")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Text("PROTOTYPE")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
                .accessibilityLabel("Throwaway prototype")
        }
    }

    private var variantSwitcher: some View {
        VStack(spacing: 4) {
            Text(variant.question)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button { variant.advance(by: -1) } label: {
                    Label("Previous variant", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Menu {
                    Picker("Variant", selection: $variant) {
                        ForEach(KanbanPrototypeVariant.allCases) { variant in
                            Text(variant.shortName).tag(variant)
                        }
                    }
                } label: {
                    Text(variant.shortName)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 165)
                }

                Button { variant.advance(by: 1) } label: {
                    Label("Next variant", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).stroke(.orange.opacity(0.65), lineWidth: 1)
        }
        .shadow(radius: 8, y: 3)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let message = store.feedbackMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: .capsule)
                .overlay { Capsule().stroke(.secondary.opacity(0.35)) }
                .padding(.top, 8)
                .onTapGesture { store.feedbackMessage = nil }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Variant A: Status Focus

private struct KanbanStatusFocusPrototype: View {
    let store: KanbanPrototypeStore
    let openCard: (KanbanPrototypeCard) -> Void
    let newCard: () -> Void
    let showFilters: () -> Void
    let showBulkActions: () -> Void
    let showDispatcher: () -> Void
    let showBoards: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            statusFocusHeader
            statusStrip

            List {
                Section {
                    if cards.isEmpty {
                        Text("No Cards match these filters in \(store.selectedStatus.label).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(cards) { card in
                            KanbanPrototypeCardRow(
                                card: card,
                                isSelected: store.selectedCardIDs.contains(card.id),
                                selectionAction: { store.toggleSelection(of: card) },
                                openAction: { openCard(card) },
                                moveAction: { store.move(cardID: card.id, to: $0) }
                            )
                        }
                    }
                } header: {
                    Text("\(store.selectedStatus.label), \(cards.count) Cards")
                }
            }
            .listStyle(.plain)
            .refreshable { store.feedbackMessage = "Refreshed the current Board." }

            if !store.selectedCardIDs.isEmpty {
                selectionBar
            }
        }
    }

    private var cards: [KanbanPrototypeCard] { store.cards(in: store.selectedStatus) }

    private var statusFocusHeader: some View {
        HStack {
            Button(action: showBoards) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BOARD").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(store.currentBoard).font(.headline)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: showFilters) {
                Image(systemName: store.activeFilterCount == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.activeFilterCount == 0 ? "Filters" : "Filters, \(store.activeFilterCount) active")

            Menu {
                Button("Preview Dispatch", systemImage: "eye", action: showDispatcher)
                Button("Run Dispatcher", systemImage: "play.fill", action: showDispatcher)
            } label: {
                Label("Dispatcher", systemImage: "bolt")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background {
                        Capsule()
                            .stroke(Color(uiColor: .separator), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)

            Button(action: newCard) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 36, height: 36)
                    .background(Color.primary, in: .circle)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("New Card")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KanbanPrototypeStatus.boardCases) { status in
                    Button {
                        store.selectedStatus = status
                    } label: {
                        HStack(spacing: 6) {
                            Text(status.label)
                            Text("\(store.count(in: status))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(store.selectedStatus == status ? .white.opacity(0.8) : .secondary)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.selectedStatus == status ? status.color : Color(.tertiarySystemFill))
                    .foregroundStyle(store.selectedStatus == status ? .white : .primary)
                    .accessibilityLabel("\(status.label), \(store.count(in: status)) Cards")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private var selectionBar: some View {
        HStack {
            Button("Clear") { store.clearSelection() }
            Spacer()
            Text("\(store.selectedCardIDs.count) selected").font(.subheadline.weight(.semibold))
            Spacer()
            Button("Bulk Actions", action: showBulkActions).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Variant B: Swipeable Board

private struct KanbanSwipeableBoardPrototype: View {
    let store: KanbanPrototypeStore
    let openCard: (KanbanPrototypeCard) -> Void
    let newCard: () -> Void
    let showFilters: () -> Void
    let showBulkActions: () -> Void
    let showDispatcher: () -> Void
    let showBoards: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            boardToolbar
            compatibilityNote

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(KanbanPrototypeStatus.boardCases) { status in
                        boardColumn(status)
                            .containerRelativeFrame(.horizontal, count: 1, spacing: 12)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)

            if !store.selectedCardIDs.isEmpty {
                HStack {
                    Text("\(store.selectedCardIDs.count) selected")
                    Spacer()
                    Button("Clear") { store.clearSelection() }
                    Button("Bulk Actions", action: showBulkActions).buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private var boardToolbar: some View {
        HStack {
            Button(action: showBoards) {
                Label(store.currentBoard, systemImage: "rectangle.3.group")
                    .font(.headline)
            }
            .buttonStyle(.plain)

            Spacer()
            Button(action: showFilters) { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                .labelStyle(.iconOnly)
            Button(action: showDispatcher) { Label("Dispatcher", systemImage: "bolt.circle") }
                .labelStyle(.iconOnly)
            Button(action: newCard) { Label("New Card", systemImage: "plus.circle.fill") }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var compatibilityNote: some View {
        Text("Swipe between Columns. Drag a Card, or use its visible Move button for the same action.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    private func boardColumn(_ status: KanbanPrototypeStatus) -> some View {
        let cards = store.cards(in: status)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(status.label, systemImage: status.systemImage)
                    .font(.headline)
                    .foregroundStyle(status.color)
                Spacer()
                Text("\(cards.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        KanbanPrototypeBoardCard(
                            card: card,
                            isSelected: store.selectedCardIDs.contains(card.id),
                            selectionAction: { store.toggleSelection(of: card) },
                            openAction: { openCard(card) },
                            moveAction: { store.move(cardID: card.id, to: $0) }
                        )
                        .draggable(card.id.uuidString)
                    }

                    if cards.isEmpty {
                        Text("Drop or move a Card here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }
                }
                .padding(10)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        .dropDestination(for: String.self) { ids, _ in
            guard status != .running,
                  let rawID = ids.first,
                  let id = UUID(uuidString: rawID) else { return false }
            store.move(cardID: id, to: status)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.label), \(cards.count) Cards")
    }
}

// MARK: - Variant C: Command Center

private struct KanbanCommandCenterPrototype: View {
    let store: KanbanPrototypeStore
    let openCard: (KanbanPrototypeCard) -> Void
    let newCard: () -> Void
    let showFilters: () -> Void
    let showBulkActions: () -> Void
    let showDispatcher: () -> Void
    let showBoards: () -> Void

    var body: some View {
        List {
            Section { commandHeader }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section("Workflow snapshot") { statusGrid }

            Section("Cards, \(store.filteredCards.count)") {
                ForEach(store.filteredCards.sorted(by: cardSort)) { card in
                    KanbanPrototypeCardRow(
                        card: card,
                        isSelected: store.selectedCardIDs.contains(card.id),
                        selectionAction: { store.toggleSelection(of: card) },
                        openAction: { openCard(card) },
                        moveAction: { store.move(cardID: card.id, to: $0) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top) {
            if !store.selectedCardIDs.isEmpty {
                HStack {
                    Text("\(store.selectedCardIDs.count) selected").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Clear") { store.clearSelection() }
                    Button("Bulk Actions", action: showBulkActions).buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private var commandHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: showBoards) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT BOARD").font(.caption2).foregroundStyle(.secondary)
                        Label(store.currentBoard, systemImage: "chevron.down")
                            .font(.title3.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: newCard) { Label("New Card", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Button(action: showFilters) {
                    Label(store.activeFilterCount == 0 ? "Filters" : "Filters \(store.activeFilterCount)", systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Preview", systemImage: "eye", action: showDispatcher)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Preview Dispatch")
                Button("Run", systemImage: "bolt.fill", action: showDispatcher)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityLabel("Run Dispatcher")
            }

            TextField(
                "Search Cards",
                text: Binding(get: { store.searchText }, set: { store.searchText = $0 })
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityHint("Searches Card titles and descriptions")
        }
        .padding(.vertical, 8)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 10) {
            ForEach(KanbanPrototypeStatus.boardCases) { status in
                Button {
                    store.selectedStatusFilter = store.selectedStatusFilter == status ? nil : status
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(status.label, systemImage: status.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.color)
                        Text("\(store.count(in: status))")
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        store.selectedStatusFilter == status ? status.color.opacity(0.16) : Color(.secondarySystemBackground),
                        in: .rect(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(status.label), \(store.count(in: status)) Cards")
                .accessibilityHint("Filters the Card list")
            }
        }
        .padding(.vertical, 4)
    }

    private func cardSort(_ lhs: KanbanPrototypeCard, _ rhs: KanbanPrototypeCard) -> Bool {
        if lhs.priority == rhs.priority {
            return KanbanPrototypeStatus.allCases.firstIndex(of: lhs.status) ?? 0
                < KanbanPrototypeStatus.allCases.firstIndex(of: rhs.status) ?? 0
        }
        return lhs.priority > rhs.priority
    }
}

// MARK: - Shared prototype controls

private struct KanbanPrototypeCardRow: View {
    let card: KanbanPrototypeCard
    let isSelected: Bool
    let selectionAction: () -> Void
    let openAction: () -> Void
    let moveAction: (KanbanPrototypeStatus) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: selectionAction) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(card.title)" : "Select \(card.title)")

            Button(action: openAction) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title).font(.headline).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text("P\(card.priority)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(card.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: card.status.systemImage)
                                .accessibilityHidden(true)
                            Text(card.status.label)
                        }
                        .foregroundStyle(card.status.color)

                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                                .accessibilityHidden(true)
                            Text(card.assignedProfile ?? "Unassigned")
                                .lineLimit(1)
                        }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .secondarySystemFill), in: .capsule)
                        Spacer()
                        Text(card.age)
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.plain)

            KanbanPrototypeMoveMenu(card: card, moveAction: moveAction)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct KanbanPrototypeBoardCard: View {
    let card: KanbanPrototypeCard
    let isSelected: Bool
    let selectionAction: () -> Void
    let openAction: () -> Void
    let moveAction: (KanbanPrototypeStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Button(action: selectionAction) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("P\(card.priority)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: openAction) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title).font(.headline).multilineTextAlignment(.leading)
                    Text(card.body).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .accessibilityHidden(true)
                    Text(card.assignedProfile ?? "Unassigned")
                        .lineLimit(1)
                }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(uiColor: .secondarySystemFill), in: .capsule)
                Spacer()
                KanbanPrototypeMoveMenu(card: card, moveAction: moveAction, label: "Move")
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

private struct KanbanPrototypeMoveMenu: View {
    let card: KanbanPrototypeCard
    let moveAction: (KanbanPrototypeStatus) -> Void
    var label = "Move Card"

    var body: some View {
        Menu {
            ForEach(KanbanPrototypeStatus.directlyMovableCases.filter { $0 != card.status }) { status in
                Button { moveAction(status) } label: {
                    Label(status == .archived ? "Archive Card" : "Move to \(status.label)", systemImage: status.systemImage)
                }
            }
            Divider()
            Label("Running is Dispatcher-owned", systemImage: "info.circle")
        } label: {
            if label == "Move" {
                Label(label, systemImage: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Move \(card.title)")
        .accessibilityHint("Choose a Status. Running is controlled by the Dispatcher.")
    }
}

private struct KanbanPrototypeCardEditor: View {
    let profiles: [String]
    let isNew: Bool
    let onSave: (KanbanPrototypeCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: KanbanPrototypeCard
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, body }

    init(
        card: KanbanPrototypeCard,
        profiles: [String],
        isNew: Bool = false,
        onSave: @escaping (KanbanPrototypeCard) -> Void
    ) {
        self.profiles = profiles
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: card)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .focused($focusedField, equals: .title)
                    TextField("Description", text: $draft.body, axis: .vertical)
                        .lineLimit(4...8)
                        .focused($focusedField, equals: .body)
                }
                Section("Workflow") {
                    Picker("Status", selection: $draft.status) {
                        ForEach(KanbanPrototypeStatus.directlyMovableCases) { status in
                            Text(status.label).tag(status)
                        }
                    }
                    Picker("Assigned Profile", selection: $draft.assignedProfile) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(profiles, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 0...10)
                }
                if !isNew {
                    Section("Operational details") {
                        LabeledContent("Prerequisites", value: "\(draft.prerequisiteCount)")
                        LabeledContent("Dependents", value: "\(draft.dependentCount)")
                        LabeledContent("Comments", value: "\(draft.commentCount)")
                        NavigationLink("Runs and worker log") {
                            ContentUnavailableView("Prototype detail", systemImage: "terminal", description: Text("A production Card would show Dispatch Runs and the worker log here."))
                        }
                    }
                    Section("Discussion") {
                        Text("Reviewer · The partial-result copy should name failed Cards.")
                        Button("Add Comment", systemImage: "plus.bubble") { draft.commentCount += 1 }
                    }
                }
                Section {
                    Text("Running is intentionally absent: only the Dispatcher can claim a Card into Running.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isNew ? "New Card" : "Card Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if isNew { focusedField = .title } }
        }
    }
}

private struct KanbanPrototypeFiltersSheet: View {
    let store: KanbanPrototypeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: Binding(get: { store.selectedStatusFilter }, set: { store.selectedStatusFilter = $0 })) {
                        Text("All Statuses").tag(KanbanPrototypeStatus?.none)
                        ForEach(KanbanPrototypeStatus.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Section("Assigned Profile") {
                    Picker("Profile", selection: Binding(get: { store.selectedProfile }, set: { store.selectedProfile = $0 })) {
                        Text("All Profiles").tag(String?.none)
                        ForEach(store.profiles, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Section {
                    Button("Clear Filters", role: .destructive) {
                        store.selectedStatusFilter = nil
                        store.selectedProfile = nil
                        store.searchText = ""
                    }
                }
            }
            .navigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct KanbanPrototypeBulkActionsSheet: View {
    let store: KanbanPrototypeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("\(store.selectedCardIDs.count) Cards selected") {
                    Menu("Change Status", systemImage: "arrowshape.turn.up.right") {
                        ForEach(KanbanPrototypeStatus.directlyMovableCases) { status in
                            Button(status == .archived ? "Archive Cards" : status.label) {
                                store.bulkMove(to: status)
                                dismiss()
                            }
                        }
                    }
                    Menu("Assign Profile", systemImage: "person.crop.circle.badge.checkmark") {
                        Button("Unassigned") { store.bulkAssign(profile: nil); dismiss() }
                        ForEach(store.profiles, id: \.self) { profile in
                            Button(profile) { store.bulkAssign(profile: profile); dismiss() }
                        }
                    }
                    Button("Set Priority", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                        store.feedbackMessage = "Set Priority would open a 0–10 picker."
                        dismiss()
                    }
                    Button("Archive Cards", systemImage: "archivebox", role: .destructive) {
                        store.archiveSelection()
                        dismiss()
                    }
                }
                Section {
                    Text("Bulk updates may partially succeed. The result must identify each failed Card and keep successful changes visible.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bulk Actions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct KanbanPrototypeDispatcherSheet: View {
    let store: KanbanPrototypeStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRun = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("3 Ready Cards are eligible", systemImage: "checkmark.circle")
                    Label("1 Card is unassigned", systemImage: "person.crop.circle.badge.questionmark")
                    Label("Maximum 8 workers", systemImage: "person.3")
                } header: { Text("Preview") }
                Section {
                    Button("Preview Dispatch", systemImage: "eye") {
                        store.feedbackMessage = "Preview complete: 3 eligible, 1 skipped as unassigned."
                        dismiss()
                    }
                    Button("Run Dispatcher", systemImage: "bolt.fill", role: .destructive) {
                        isConfirmingRun = true
                    }
                }
                Section {
                    Text("Run Dispatcher may start workers and consume API budget. Preview does not spawn workers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dispatcher")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Run Dispatcher?", isPresented: $isConfirmingRun, titleVisibility: .visible) {
                Button("Run Dispatcher", role: .destructive) {
                    store.feedbackMessage = "Prototype only — would run the Dispatcher after confirmation."
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This may launch workers and consume API budget.")
            }
        }
        .presentationDetents([.medium])
    }
}

private struct KanbanPrototypeBoardsSheet: View {
    let store: KanbanPrototypeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.boards, id: \.self) { board in
                        Button {
                            store.currentBoard = board
                            store.feedbackMessage = "Switched the server’s shared active Board to \(board)."
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(board)
                                    Text(board == store.currentBoard ? "Current shared Board" : "Tap to switch")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if board == store.currentBoard { Image(systemName: "checkmark") }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: { Text("Boards") } footer: {
                    Text("Switching changes the server-global current Board used by the CLI, dashboard, and other WebUI tabs.")
                }
                Section("Manage") {
                    Button("New Board", systemImage: "plus.rectangle") { store.feedbackMessage = "Would open the New Board form."; dismiss() }
                    Button("Edit Board", systemImage: "pencil") { store.feedbackMessage = "Would edit Board name, description, icon, and color."; dismiss() }
                    Button("Archive Board", systemImage: "archivebox", role: .destructive) { store.feedbackMessage = "Would confirm that Hermex cannot restore this Board in-app."; dismiss() }
                }
            }
            .navigationTitle("Choose Board")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    KanbanPrototypeView()
}
#endif
