import SwiftUI

/// The create and duplicate sheet: a live face, the name, an optional role, the
/// drawn look, the model and the credential choice, plus instructions and the
/// bundled-skills choice for a new bot, then one Create button.
/// After a partial create the same sheet shows each step's outcome and Try Again.
@MainActor struct BotCreateView: View {
    @State private var creator: BotCreator
    @State private var showsModels = false
    @State private var showsExpressions = false
    /// What the face should do about the last edit: a hop for a shape, a wobble
    /// for a color, a glance down while the name is typed.
    @State private var cue: BotFaceCue?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(creator: BotCreator) { _creator = State(initialValue: creator) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    BotInteractiveFaceView(name: creator.name, appearance: creator.draft.appearance, size: 150, cue: cue)
                        .padding(.top, 24).padding(.bottom, 20)
                    if creator.hasStarted { results }
                    // Once the Profile write has been dispatched these values are on the
                    // host; a retry only finishes the remaining steps, so editing them
                    // here would be a lie. Edit the bot afterwards instead.
                    card {
                        TextField("Name your bot", text: Binding(get: { creator.draft.title }, set: { creator.setTitle($0); cue = BotFaceCue(.glanceDown) }))
                            .font(.title3).multilineTextAlignment(.center)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .disabled(creator.hasStarted)
                            .padding(16)
                    }
                    if let problem = creator.nameProblem {
                        Text(problem).font(.caption).foregroundStyle(.red).padding(.top, 8).padding(.horizontal, 12)
                    } else if !creator.name.isEmpty, !creator.hasStarted {
                        Text(verbatim: creator.name).font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
                    }
                    if let source = creator.source {
                        Text("Copies \(source.name)’s instructions, settings and skills. Its chat stays with the original.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.top, 10).padding(.horizontal, 12)
                    }

                    lookCard.padding(.top, 20).disabled(creator.hasStarted)

                    sectionLabel("Setup")
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Role").font(.caption).foregroundStyle(.secondary)
                            TextField("What this bot is for (optional)", text: Binding(get: { creator.draft.role }, set: { creator.setRole($0) }), axis: .vertical)
                                .lineLimit(1...3)
                        }
                        .padding(16)
                        Divider().padding(.leading, 16)
                        navigationRow(String(localized: "Model"), subtitle: creator.draft.model?.providerID,
                                      value: creator.draft.model?.displayName ?? String(localized: "Host default"),
                                      systemImage: "cpu") { showsModels = true }
                        Divider().padding(.leading, 16)
                        Toggle(isOn: Binding(get: { creator.draft.sharesCredentials }, set: { creator.setSharesCredentials($0) })) {
                            Text("Use this Hermes’s API keys")
                        }
                        .padding(16)
                    }
                    .disabled(creator.hasStarted)
                    Text(creator.draft.sharesCredentials
                         ? "The bot signs in with the keys already saved on the host. Nothing is copied to this phone."
                         : "The bot starts with no API keys. Add them in Hermes Desktop before it can answer.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 7)

                    // A duplicate copies the source's instructions and skills, so these are new-bot only.
                    if !creator.isDuplicate { startingPoint.disabled(creator.hasStarted) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively)
            .disabled(creator.phase == .creating)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if creator.phase == .created { dismiss() } else { Task { await creator.create() } }
                } label: {
                    Group {
                        if creator.phase == .creating { ProgressView().tint(.primary) }
                        else if creator.phase == .created { Text("Done") }
                        else { Text(creator.hasStarted ? "Try Again" : creator.isDuplicate ? "Duplicate" : "Create") }
                    }
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(!creator.canCreate && creator.phase != .created)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle(creator.isDuplicate ? "Duplicate Bot" : "New Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .disabled(creator.phase == .creating)
                }
            }
            .navigationDestination(isPresented: $showsExpressions) { expressionPicker }
        }
        .interactiveDismissDisabled(creator.phase == .creating)
        .sheet(isPresented: $showsModels) { modelPicker }
        .task { await creator.load() }
        .onDisappear { creator.close() }
        .onChange(of: scenePhase) { if scenePhase != .active { creator.close() } }
        // A clean create closes on its own; one with leftovers stays up so the
        // results and the note are read before Done.
        .onChange(of: creator.phase) { if creator.phase == .created, !creator.needsAttention { dismiss() } }
    }

    /// The new bot's instructions and whether it starts with the bundled skills.
    @ViewBuilder private var startingPoint: some View {
        sectionLabel("Instructions")
        card {
            TextEditor(text: Binding(get: { creator.draft.instructions }, set: { creator.setInstructions($0) }))
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if creator.draft.instructions.isEmpty {
                        Text("How this bot should work (optional)")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Instructions")
                .padding(12)
        }
        Text("Leave empty to use the host’s default instructions.")
            .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 7)

        sectionLabel("Skills")
        card {
            Toggle(isOn: Binding(get: { creator.draft.skipsBundledSkills }, set: { creator.setSkipsBundledSkills($0) })) {
                Text("Start without bundled skills")
            }
            .padding(16)
        }
        Text(creator.draft.skipsBundledSkills
             ? "Only the host’s essential skills. Add more later from the bot’s settings."
             : "The bot starts with every skill that ships with Hermes.")
            .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 7)
    }

    private var lookCard: some View {
        card {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                ForEach(BotAvatarShape.allCases) { shape in
                    Button { creator.setShape(shape); cue = BotFaceCue(.hop) } label: {
                        BotAvatarMarkView(name: creator.name, appearance: appearance(for: shape), size: 42)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .overlay {
                                if creator.draft.appearance.shape == shape.rawValue {
                                    RoundedRectangle(cornerRadius: 12).stroke(.secondary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shape.localizedName)
                    .accessibilityAddTraits(creator.draft.appearance.shape == shape.rawValue ? .isSelected : [])
                }
            }
            .padding(16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 15) {
                ForEach(BotAvatarColor.palette) { color in
                    Button { creator.setColor(color.hex); cue = BotFaceCue(.wobble) } label: {
                        Circle().fill(color.swatch).frame(width: 30, height: 30)
                            .overlay { if creator.draft.appearance.color == color.hex { Circle().stroke(.secondary, lineWidth: 3).padding(-5) } }
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Avatar color \(color.localizedName)"))
                    .accessibilityAddTraits(creator.draft.appearance.color == color.hex ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            Divider().padding(.leading, 16)
            navigationRow(String(localized: "Expression"), subtitle: nil,
                          value: BotAvatarExpression.resolve(creator.draft.appearance.expression).localizedName,
                          systemImage: "face.smiling") { showsExpressions = true }
        }
    }

    /// Per-step outcomes after an attempt, mirroring the editor's save results.
    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(creator.phase == .created ? (creator.needsAttention ? "Created, with a note" : "Created") : "Needs Attention").font(.headline)
            ForEach(BotCreator.Step.allCases.filter { creator.outcomes[$0] != nil }) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(creator.outcomes[step]!)).foregroundStyle(color(creator.outcomes[step]!)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.subheadline.weight(.semibold))
                        Text(text(creator.outcomes[step]!)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let note = creator.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .padding(.bottom, 16)
    }

    private var expressionPicker: some View {
        List(BotAvatarExpression.allCases) { expression in
            Button { creator.setExpression(expression); showsExpressions = false } label: {
                HStack(spacing: 14) {
                    BotAvatarMarkView(name: creator.name, appearance: appearance(expression: expression), size: 40)
                    Text(expression.localizedName).foregroundStyle(.primary)
                    Spacer()
                    if BotAvatarExpression.resolve(creator.draft.appearance.expression) == expression {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
        }
        .navigationTitle("Expression").navigationBarTitleDisplayMode(.inline)
    }

    private var modelPicker: some View {
        ModelPickerSheet(
            configuration: ModelPickerConfiguration(
                navigationTitle: "Choose Model", dismissTitle: "Done", dismissPlacement: .topBarTrailing,
                customActionTitle: "Use Custom", requiresCustomProviderID: true,
                showsCustomFavoriteStar: false, showsModelFavoriteStars: false,
                showsCurrentCustomModelGroup: true, showsSavedCustomModelGroup: false, dismissesOnCommit: true
            ),
            modelGroups: creator.modelGroups, selectedModelID: creator.draft.model?.id,
            selectedModelProviderID: creator.draft.model?.providerID,
            isSelected: { creator.draft.model?.matchesSelection(modelID: $0.id, providerID: $0.providerID) == true },
            onSelect: { creator.setModel($0); showsModels = false }
        )
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10).padding(.top, 24).padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func navigationRow(_ title: String, subtitle: String?, value: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appearance(for shape: BotAvatarShape) -> BotProfileAppearance {
        var appearance = creator.draft.appearance
        appearance.shape = shape.rawValue; appearance.custom = true; appearance.imageKind = "shape"
        return appearance
    }

    private func appearance(expression: BotAvatarExpression) -> BotProfileAppearance {
        var appearance = creator.draft.appearance
        appearance.expression = expression.rawValue
        return appearance
    }

    private func icon(_ outcome: BotCreator.Outcome) -> String {
        switch outcome { case .done: return "checkmark.circle.fill"; case .uncertain: return "questionmark.circle"; case .failed: return "exclamationmark.circle" }
    }
    private func color(_ outcome: BotCreator.Outcome) -> Color {
        switch outcome { case .done: return .green; case .uncertain: return .orange; case .failed: return .red }
    }
    private func text(_ outcome: BotCreator.Outcome) -> String {
        switch outcome {
        case .done: return String(localized: "Done")
        case .failed(let message): return message
        case .uncertain: return String(localized: "Outcome Uncertain")
        }
    }
}
