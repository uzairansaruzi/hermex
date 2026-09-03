import SwiftUI

/// The create and edit sheet for a scheduled task. Both entry points — the
/// Tasks toolbar's "New Task" and a task's own Edit action — present this same
/// sheet, so the Configuration section's model and profile pickers are loaded
/// and behave identically in each.
struct CronJobEditorSheet: View {
    let title: String
    let saveTitle: String
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (CronJobEditorDraft) async -> Bool

    @State private var draft: CronJobEditorDraft
    /// The Configuration section's model catalog and profile list. Loaded when
    /// this sheet opens, not when the Tasks list appears.
    @State private var configuration: CronJobEditorConfigurationLoader
    @State private var isPresentingModelPicker = false
    @State private var isPresentingProfilePicker = false
    @Environment(\.dismiss) private var dismiss

    /// Server-provided deliver targets. A plain `let` so a re-init while the
    /// sheet is presented (options finishing their async load) swaps in the
    /// fresh list, unlike `@State draft`, which keeps the user's edits.
    private let serverDeliveryOptions: [CronDeliveryOption]?
    /// The draft's deliver value when the editor opened; stable across
    /// re-inits because callers rebuild the same draft.
    private let initialDeliver: String

    /// Picker rows recomputed from the live draft so a value typed while the
    /// options were still loading keeps a matching row, and the initial
    /// unknown/legacy value keeps its custom row even after the user selects
    /// another option. `nil` means fall back to free-text entry.
    private var deliverPickerOptions: [CronDeliverPickerOption]? {
        CronDeliverPicker.options(
            serverOptions: serverDeliveryOptions,
            currentValue: draft.deliver,
            initialValue: initialDeliver
        )
    }

    init(
        title: String,
        server: URL,
        draft: CronJobEditorDraft,
        saveTitle: String,
        isSaving: Bool,
        errorMessage: String?,
        deliveryOptions: [CronDeliveryOption]? = nil,
        onSave: @escaping (CronJobEditorDraft) async -> Bool
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.serverDeliveryOptions = deliveryOptions
        self.initialDeliver = draft.deliver
        _draft = State(initialValue: draft)
        _configuration = State(initialValue: CronJobEditorConfigurationLoader(server: server))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Name", text: $draft.name)

                    TextField("Prompt", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)

                    TextField("Schedule", text: $draft.schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Delivery") {
                    if let deliverPickerOptions {
                        Picker("Deliver", selection: $draft.deliver) {
                            ForEach(deliverPickerOptions) { option in
                                Group {
                                    if option.isCustom {
                                        Text("\(option.label) (custom)")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                                .tag(option.value)
                            }
                        }
                    } else {
                        TextField("Deliver", text: $draft.deliver)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Toggle("Toast Notifications", isOn: $draft.toastNotifications)
                }

                Section {
                    TextField("Skills", text: $draft.skillsText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    CronJobModelRow(selection: modelSelection) {
                        isPresentingModelPicker = true
                    }

                    CronJobProfileRow(
                        profileName: draft.profile,
                        profiles: configuration.profiles,
                        errorMessage: configuration.profilesErrorMessage,
                        isLoading: configuration.isLoadingProfiles,
                        action: { isPresentingProfilePicker = true },
                        onRetry: { Task { await configuration.loadProfiles() } }
                    )
                } header: {
                    Text("Configuration")
                } footer: {
                    // States what upstream already does rather than
                    // reimplementing it: `_selected_profile_snapshot_updates`
                    // fills in the model from the profile only while the model
                    // is blank, so the app must not prefill it.
                    Text("Leaving the model on Server default lets the server use the selected profile's model.")
                }

                if let formMessage {
                    Section {
                        Text(formMessage)
                            .font(.footnote)
                            .foregroundStyle(messageColor)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await configuration.load()
            }
            .sheet(isPresented: $isPresentingModelPicker) {
                ModelPickerSheet(
                    configuration: .cronJob,
                    modelGroups: configuration.modelGroups,
                    selectedModelID: draft.trimmedModel,
                    selectedModelProviderID: draft.trimmedProvider,
                    isSelected: { option in
                        option.matchesSelection(
                            modelID: draft.trimmedModel,
                            providerID: draft.trimmedProvider
                        )
                    },
                    loadStatus: modelLoadStatus,
                    clearAction: ModelPickerClearAction(
                        title: "Server default",
                        isSelected: draft.trimmedModel == nil,
                        action: { draft.applyModelSelection(nil) }
                    ),
                    onSelect: { option in
                        draft.applyModelSelection(option)
                    }
                )
            }
            .sheet(isPresented: $isPresentingProfilePicker) {
                CronJobProfilePickerSheet(
                    profiles: configuration.profiles,
                    selectedProfileName: draft.profile,
                    isLoading: configuration.isLoadingProfiles,
                    errorMessage: configuration.profilesErrorMessage,
                    onRetry: { Task { await configuration.loadProfiles() } },
                    onSelect: { name in
                        draft.applyProfileSelection(name)
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await onSave(draft) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(saveTitle)
                        }
                    }
                    .disabled(isSaving || draft.validationMessage != nil)
                }
            }
        }
        .adaptiveFormPresentation()
    }

    private var modelSelection: ModelCatalogOption? {
        CronJobModelSelection.resolve(
            modelID: draft.model,
            providerID: draft.provider,
            in: configuration.modelGroups
        )
    }

    /// A failed catalog is not fatal: the picker keeps its custom entry, so an
    /// exact model and provider ID can still be typed by hand.
    private var modelLoadStatus: ModelPickerLoadStatus {
        if configuration.isLoadingModels, configuration.modelGroups.isEmpty { return .loading }
        if let message = configuration.modelsErrorMessage, configuration.modelGroups.isEmpty {
            return .failed(message)
        }
        return .loaded
    }

    private var formMessage: String? {
        errorMessage ?? draft.validationMessage
    }

    private var messageColor: Color {
        errorMessage == nil ? .secondary : .red
    }
}
