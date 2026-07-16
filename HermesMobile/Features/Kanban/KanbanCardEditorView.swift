import SwiftUI

struct KanbanCardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: KanbanCardEditorState
    let allowsMutation: Bool
    let onSaved: @MainActor () async -> Void

    @FocusState private var focusedField: Field?
    @State private var showsReadyWarning = false
    @State private var showsReloadConfirmation = false
    @State private var hasConfirmedReadyUnassigned = false

    private enum Field: Hashable {
        case title, body, tenant, priority, workspacePath, skills, maximumRuntime, prerequisite
    }

    var body: some View {
        NavigationStack {
            Form {
                primaryFields
                assignmentFields
                if state.isEditing {
                    createOnlyFields.disabled(true)
                } else {
                    createOnlyFields
                }
                submissionSection
            }
            .disabled(state.submission.isInFlight)
            .navigationTitle(state.isEditing ? String(localized: "Edit Card") : String(localized: "New Card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .interactiveDismissDisabled(state.submission.isInFlight)
            .onChange(of: state.submission) { _, submission in
                handle(submission)
            }
            .alert("Create Ready, Unassigned Card?", isPresented: $showsReadyWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    hasConfirmedReadyUnassigned = true
                    submit()
                }
            } message: {
                Text("The Dispatcher skips Ready Cards without an Assigned Profile.")
            }
            .alert("Reload Server Version?", isPresented: $showsReloadConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reload", role: .destructive) { state.reloadServerVersion() }
            } message: {
                Text("Your local draft will be discarded.")
            }
        }
    }

    private var primaryFields: some View {
        Section {
            TextField("Title", text: $state.title)
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .body }
                .accessibilityLabel(Text("Title"))
                .accessibilityHint(Text("Required"))

            TextField("Description", text: $state.body, axis: .vertical)
                .lineLimit(4...12)
                .focused($focusedField, equals: .body)

            Picker("Status", selection: $state.status) {
                if state.isEditing, let originalStatus = state.originalStatus,
                   !KanbanCardEditorState.createStatuses.contains(originalStatus) {
                    Text(KanbanStatusPresentation(originalStatus).title)
                        .tag(originalStatus)
                        .disabled(true)
                }
                Text("Triage").tag("triage")
                Text("To Do").tag("todo")
                Text("Ready").tag("ready")
            }

            LabeledContent("Priority") {
                TextField("Priority", text: $state.priorityText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .priority)
                    .accessibilityLabel(Text("Priority"))
                    .accessibilityHint(Text("A whole number from -100 through 100."))
            }
        } header: {
            Text("Card")
        } footer: {
            if state.isEditing, let originalStatus = state.originalStatus,
               !KanbanCardEditorState.createStatuses.contains(originalStatus) {
                Text("Current Status: \(KanbanStatusPresentation(originalStatus).title). Choose a permitted Status only if you want to move the Card.")
            }
        }
    }

    private var assignmentFields: some View {
        Section {
            Picker("Profile", selection: $state.assignee) {
                Text("Unassigned").tag(String?.none)
                ForEach(state.profileOptions, id: \.self) { profile in
                    Text(verbatim: profile).tag(Optional(profile))
                }
            }

            TextField("Tenant", text: $state.tenant)
                .focused($focusedField, equals: .tenant)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !state.tenantOptions.isEmpty {
                Menu("Choose Tenant") {
                    Button("None") { state.tenant = "" }
                    ForEach(state.tenantOptions, id: \.self) { tenant in
                        Button(tenant) { state.tenant = tenant }
                    }
                }
            }
        } header: {
            Text("Assignment")
        }
    }

    private var createOnlyFields: some View {
        Section {
            Picker("Workspace", selection: $state.workspaceKind) {
                Text("Scratch").tag("scratch")
                Text("Worktree").tag("worktree")
                Text("Directory").tag("dir")
            }

            if state.workspaceKind != "scratch" || state.isEditing {
                TextField("Workspace path", text: $state.workspacePath)
                    .focused($focusedField, equals: .workspacePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            TextField("Skills", text: $state.skillsText)
                .focused($focusedField, equals: .skills)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityHint(Text("Separate skill names with commas."))

            LabeledContent("Maximum Runtime") {
                TextField("Maximum Runtime", text: $state.maximumRuntimeText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .maximumRuntime)
                    .accessibilityLabel(Text("Maximum Runtime"))
                    .accessibilityHint(Text("Optional number of seconds."))
            }

            TextField("Prerequisite", text: $state.prerequisiteID)
                .focused($focusedField, equals: .prerequisite)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !state.prerequisiteOptions.isEmpty {
                Menu("Choose Prerequisite") {
                    Button("None") { state.prerequisiteID = "" }
                    ForEach(state.prerequisiteOptions, id: \.cardID) { card in
                        if let cardID = card.cardID {
                            Button(card.title.map { "\(cardID) — \($0)" } ?? cardID) {
                                state.prerequisiteID = cardID
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Execution")
        } footer: {
            if state.isEditing {
                Text("Workspace, Skills, Maximum Runtime, and Prerequisite are set when the Card is created and cannot be edited here.")
            }
        }
    }

    @ViewBuilder
    private var submissionSection: some View {
        switch state.submission {
        case .idle, .saving, .succeeded:
            EmptyView()
        case .validationFailed:
            Section {
                Label(state.validationMessage ?? String(localized: "The server rejected the request."), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        case .checkingResult:
            Section {
                Label("Checking Result", systemImage: "arrow.triangle.2.circlepath")
            }
        case .failed:
            Section {
                Label("Failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button("Try Again") { beginSubmit() }
            }
        case .outcomeUncertain:
            Section {
                Label("Outcome Uncertain", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text("Refresh the Board before trying again.")
                Button("Try Again") { beginSubmit() }
            }
        case .conflict:
            Section {
                Label("Conflict", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Text("This Card changed on the server after the editor opened. Your draft has been preserved.")
                if let remote = state.remoteCard {
                    LabeledContent("Server Title") { Text(remote.title ?? String(localized: "Untitled Task")) }
                    LabeledContent("Server Status") {
                        Text(KanbanStatusPresentation(remote.status?.rawValue ?? "").title)
                    }
                }
                Button("Reload Server Version") { showsReloadConfirmation = true }
                Button("Review and Overwrite") {
                    Task { await state.save(allowsMutation: allowsMutation, readyUnassignedConfirmed: true, overwriteConflict: true) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(state.submission.isInFlight)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                beginSubmit()
            } label: {
                if state.submission.isInFlight {
                    ProgressView().accessibilityLabel(Text("Saving"))
                } else {
                    Text(state.isEditing ? "Save" : "Create")
                }
            }
            .disabled(!allowsMutation || !state.canSubmit)
        }
    }

    private func beginSubmit() {
        if state.needsReadyUnassignedConfirmation && !hasConfirmedReadyUnassigned {
            showsReadyWarning = true
        } else {
            submit()
        }
    }

    private func submit() {
        Task {
            await state.save(
                allowsMutation: allowsMutation,
                readyUnassignedConfirmed: hasConfirmedReadyUnassigned
            )
        }
    }

    private func handle(_ submission: KanbanCardEditorSubmission) {
        switch submission {
        case let .validationFailed(field):
            switch field {
            case .title: focusedField = .title
            case .priority: focusedField = .priority
            case .workspacePath: focusedField = .workspacePath
            case .maximumRuntime: focusedField = .maximumRuntime
            case .prerequisite: focusedField = .prerequisite
            case .status: break
            }
        case .succeeded:
            Task {
                await onSaved()
                dismiss()
            }
        default:
            break
        }
    }
}
