import SwiftUI

/// Uses the exact Sessions toolbar controls, with a Bot-owned transport and state.
struct BotComposerSettings: View {
    let settings: BotChatControls
    let preparePresentation: () -> Void
    let dismissPresentation: () -> Void
    @State private var showsModels = false
    @State private var showsWorkspace = false
    @State private var sheetContext: BotChatControls.Context?

    var body: some View {
        let owner = settings.context
        HStack(spacing: 8) {
            if let active = settings.catalog.active {
                ComposerModelEffortMenu(
                    allowsEffortChanges: settings.mayChangeEffort,
                    selection: ComposerModelEffortSelection(
                        model: active, effort: settings.effort,
                        supportedEfforts: BotModelCatalog.effortLevels,
                        supportsEffort: settings.supportsEffort
                    ),
                    modelGroups: settings.catalog.groups, favoriteModelKeys: [], recentModelKeys: [],
                    isDisabled: !settings.mayChangeModel, color: .secondary,
                    controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2(),
                    onSelectModel: { selectModel($0, context: owner) }, onSelectEffort: { change(.effort($0), context: owner) },
                    onShowAllModels: { sheetContext = owner; preparePresentation(); showsModels = true }
                )
            }
            if let workspace = settings.workspace {
                ComposerWorkspaceSelectorButton(
                    title: workspace.lastPathComponentFallback,
                    isDisabled: !settings.mayChangeWorkspace, color: .secondary,
                    controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2()
                ) { sheetContext = owner; preparePresentation(); showsWorkspace = true }
            }
            if let fast = settings.fast, settings.showsFast {
                Button { change(.fast(!fast), context: owner) } label: {
                    ComposerInlineControlLabel(
                        title: fast ? String(localized: "Fast") : String(localized: "Normal"),
                        systemImage: "bolt", showsChevron: false, color: .secondary,
                        controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2()
                    )
                }
                .buttonStyle(.plain)
                .disabled(!settings.mayChangeFast)
                .accessibilityLabel("Fast")
                .accessibilityValue(fast ? String(localized: "On") : String(localized: "Off"))
            }
            ContextWindowIndicatorView(snapshot: settings.usage.hasContext ? settings.usage.snapshot : nil)
                .padding(.horizontal, 4)
        }
        .onChange(of: settings.context) {
            showsModels = false; showsWorkspace = false; sheetContext = nil
        }
        .onChange(of: showsModels || showsWorkspace) { _, presented in
            if !presented { dismissPresentation() }
        }
        .sheet(isPresented: $showsModels) {
            ModelPickerSheet(
                configuration: Self.pickerConfiguration, modelGroups: settings.catalog.groups,
                selectedModelID: settings.catalog.active?.id,
                selectedModelProviderID: settings.catalog.active?.providerID,
                isSelected: { settings.catalog.active?.matchesSelection(modelID: $0.id, providerID: $0.providerID) == true },
                isSelectionDisabled: !settings.mayChangeModel, errorMessage: settings.errorMessage,
                onSelect: { option in showsModels = false; selectModel(option, context: sheetContext) }
            )
        }
        .sheet(isPresented: $showsWorkspace) {
            ComposerWorkspacePickerSheet(
                allowsCustomPath: true, workspaceRoots: [], selectedWorkspacePath: settings.workspace,
                suggestions: [], onLoadSuggestions: { _ in }, onSelect: { path in
                    guard settings.context == sheetContext, let action = settings.prepare(.workspace(path)) else { return }
                    await settings.apply(action)
                }
            )
        }
    }

    private func selectModel(_ option: ModelCatalogOption, context: BotChatControls.Context?) {
        change(.model(option), context: context)
    }

    private func change(_ change: BotChatControls.Change, context: BotChatControls.Context?) {
        guard settings.context == context, let action = settings.prepare(change) else { return }
        Task { await settings.apply(action) }
    }

    private static let pickerConfiguration = ModelPickerConfiguration(
        navigationTitle: "Choose Model", dismissTitle: "Done", dismissPlacement: .topBarTrailing,
        customActionTitle: "Use Custom", requiresCustomProviderID: true,
        showsCustomFavoriteStar: false, showsModelFavoriteStars: false,
        showsCurrentCustomModelGroup: true, showsSavedCustomModelGroup: false, dismissesOnCommit: true
    )
}

struct BotSessionControlMenu: View {
    let settings: BotChatControls
    @State private var action: BotChatControls.Action?

    var body: some View {
        Menu {
            ForEach(settings.controls) { control in
                Section(control.title) {
                    Text(control.status == "active" ? String(localized: "Active") : control.status == "paused" ? String(localized: "Paused") : control.status)
                    if control.action != nil {
                        Button(control.actionTitle) { action = settings.prepare(.control(control)) }
                            .disabled(!settings.mayControl)
                    }
                }
            }
        } label: { Label("Session controls", systemImage: "slider.horizontal.3") }
        .confirmationDialog("Change session control?", isPresented: Binding(
            get: { action != nil }, set: { if !$0 { action = nil } }
        ), titleVisibility: .visible) {
            if let captured = action, case .control(let control) = captured.change {
                Button(control.actionTitle) { action = nil; Task { await settings.apply(captured) } }
            }
            Button("Cancel", role: .cancel) { action = nil }
        } message: {
            if let action, case .control(let control) = action.change { Text(control.consequence) }
        }
        .onChange(of: settings.context) { action = nil }
    }
}
