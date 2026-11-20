import SwiftUI

struct CronJobEditorSheet: View {
    let title: String
    let saveTitle: String
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (CronJobEditorDraft) async -> Bool
    private let server: URL
    private let client: any CronDataClient
    private let locksProfile: Bool

    @State private var draft: CronJobEditorDraft
    @State private var configuration: CronJobEditorConfigurationLoader
    @State private var isPresentingModelPicker = false
    @State private var isPresentingProfilePicker = false
    @State private var isPresentingSkillsPicker = false
    @State private var draftAtProfilePick: CronJobEditorDraft?
    @Environment(\.dismiss) private var dismiss

    private let serverDeliveryOptions: [CronDeliveryOption]?
    private let initialDeliver: String

    private var deliverPickerOptions: [CronDeliverPickerOption]? {
        CronDeliverPicker.options(
            serverOptions: configuration.deliveryOptions ?? serverDeliveryOptions,
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
        client: (any CronDataClient)? = nil,
        locksProfile: Bool = false,
        onSave: @escaping (CronJobEditorDraft) async -> Bool
    ) {
        let client = client ?? APIClient(baseURL: server)
        self.title = title
        self.saveTitle = saveTitle
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.server = server
        self.client = client
        self.locksProfile = locksProfile
        self.serverDeliveryOptions = deliveryOptions
        self.initialDeliver = draft.deliver
        _draft = State(initialValue: draft)
        _configuration = State(initialValue: CronJobEditorConfigurationLoader(
            server: server, client: client, profile: draft.trimmedProfile
        ))
    }

    var body: some View {
        NavigationStack {
            AppForm {
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

                    if client.cronFeatures.hasToastNotifications {
                        Toggle("Toast Notifications", isOn: $draft.toastNotifications)
                    }
                }

                Section {
                    CronJobSkillsRow(
                        selection: draft.skills,
                        errorMessage: configuration.skillsErrorMessage,
                        isLoading: configuration.isLoadingSkills,
                        action: { isPresentingSkillsPicker = true },
                        onRetry: { Task { await configuration.loadSkills() } }
                    )

                    CronJobModelRow(selection: modelSelection) {
                        isPresentingModelPicker = true
                    }

                    CronJobProfileRow(
                        profileName: draft.profile,
                        profiles: configuration.profiles,
                        errorMessage: configuration.profilesErrorMessage,
                        isLoading: configuration.isLoadingProfiles,
                        isLocked: locksProfile,
                        action: { isPresentingProfilePicker = true },
                        onRetry: { Task { await configuration.loadProfiles() } }
                    )
                } header: {
                    Text("Configuration")
                } appFooter: {
                    Text("Leaving the model on Server default lets the server use the selected profile's model.")
                }

                if let formMessage {
                    Section {
                        Text(formMessage)
                            .font(AppFont.footnote())
                            .foregroundStyle(messageColor)
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: ObjectIdentifier(configuration)) {
                let loader = configuration
                await loader.load()
                guard let earlier = draftAtProfilePick, !Task.isCancelled else { return }
                draftAtProfilePick = nil
                draft.keepChoices(madeBefore: earlier, offeredTargets: loader.deliveryOptions?.compactMap(\.value),
                                  offeredSkills: loader.skillsErrorMessage == nil ? loader.skills.compactMap(\.name) : nil)
            }
            .onChange(of: draft.trimmedProfile) { _, profile in
                guard client.cronFeatures.isProfileScoped else { return }
                if draftAtProfilePick == nil { draftAtProfilePick = draft }
                configuration = CronJobEditorConfigurationLoader(server: server, client: client, profile: profile)
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
            .sheet(isPresented: $isPresentingSkillsPicker) {
                CronJobSkillsPickerSheet(
                    skills: configuration.skills,
                    selection: draft.skills,
                    isLoading: configuration.isLoadingSkills,
                    errorMessage: configuration.skillsErrorMessage,
                    onRetry: { Task { await configuration.loadSkills() } },
                    onToggle: { name in
                        draft.applySkillSelection(
                            CronJobEditorDraft.togglingSkill(name, in: draft.skills)
                        )
                    },
                    onClear: { draft.applySkillSelection([]) }
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
        errorMessage == nil ? Color(.appTextSecondary) : .red
    }
}
