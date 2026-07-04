import SwiftUI

struct TasksView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: TasksViewModel
    @State private var isPresentingCreateTask = false

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: TasksViewModel(server: server))
    }

    var body: some View {
        content
            .navigationTitle("Automations")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearActionError()
                        isPresentingCreateTask = true
                    } label: {
                        Label("New Automation", systemImage: "plus")
                    }
                    .disabled(viewModel.isMutating)

                    Button {
                        Task { await loadAutomations() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .sheet(isPresented: $isPresentingCreateTask) {
                CronJobEditorSheet(
                    title: String(localized: "New Automation"),
                    draft: CronJobEditorDraft(),
                    saveTitle: String(localized: "Create"),
                    isSaving: viewModel.isMutating,
                    errorMessage: viewModel.actionErrorMessage,
                    showsDescriptorDraftFlow: true
                ) { draft in
                    let didCreate = await viewModel.create(from: draft)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didCreate
                }
            }
            .task {
                await loadAutomations()
            }
            .zoraBrandedScreen()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.jobs.isEmpty {
            ProgressView("Loading automations...")
        } else if let errorMessage = viewModel.errorMessage, viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Automations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadAutomations() }
                }
            }
        } else if viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label("No Automations", systemImage: "calendar.badge.clock")
            } description: {
                Text("Scheduled automations from the Hermes server will appear here.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    runningSummaryRow
                        .padding(.bottom, 22)

                    Text("Scheduled Automations")
                        .textCase(.uppercase)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(ZoraBrand.secondaryForeground)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)

                    ForEach(Array(viewModel.jobs.enumerated()), id: \.element.id) { index, job in
                        NavigationLink {
                            TaskDetailView(
                                job: job,
                                runningElapsed: viewModel.runningElapsed(for: job),
                                server: server,
                                onAPIError: onAPIError,
                                onMutation: { mutation in
                                    viewModel.apply(mutation)
                                }
                            )
                        } label: {
                            CronJobRowView(
                                job: job,
                                runningElapsed: viewModel.runningElapsed(for: job)
                            )
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < viewModel.jobs.count - 1 {
                            Divider()
                                .overlay(ZoraBrand.listDivider)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zoraAdaptiveContentFrame(.readablePage)
            }
            .refreshable {
                await loadAutomations()
            }
            .background(Color.clear)
        }
    }

    private var runningSummaryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.selectionAccent)
                .frame(width: 34, height: 34)
                .background(ZoraBrand.selectionAccent.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Running now")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(ZoraBrand.foreground)

                Text("Active scheduled work")
                    .font(AppFont.caption())
                    .foregroundStyle(ZoraBrand.secondaryForeground)
            }

            Spacer(minLength: 12)

            Text("\(viewModel.activeRunningCount)")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(ZoraBrand.foreground)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func loadAutomations() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

private struct CronJobRowView: View {
    let job: CronJob
    let runningElapsed: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(2)

                if let subtitle = compactSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            StatusBadge(
                text: runningElapsed == nil ? job.status.label : String(localized: "Running"),
                color: statusColor
            )
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var compactSubtitle: String? {
        if let runningElapsed {
            return String(localized: "Running for \(Self.elapsedText(runningElapsed))")
        }

        if let nextRunAt = job.nextRunAt?.formatted {
            return String(localized: "Next \(nextRunAt)")
        }

        if let lastRunAt = job.lastRunAt?.formatted {
            return String(localized: "Last \(lastRunAt)")
        }

        guard let schedule = job.scheduleText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !schedule.isEmpty
        else {
            return nil
        }

        return schedule
    }

    private var statusColor: Color {
        if runningElapsed != nil {
            return .blue
        }

        switch job.status {
        case .active:
            return .green
        case .paused, .off:
            return .orange
        case .error:
            return .red
        case .needsAttention:
            return .yellow
        }
    }

    private static func elapsedText(_ elapsed: Double) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed.rounded()))s"
        }

        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }
}

struct CronJobEditorSheet: View {
    let title: String
    let saveTitle: String
    let isSaving: Bool
    let errorMessage: String?
    let showsDescriptorDraftFlow: Bool
    let onSave: (CronJobEditorDraft) async -> Bool

    @State private var draft: CronJobEditorDraft
    @State private var descriptor = ""
    @State private var descriptorSummary: String?
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        draft: CronJobEditorDraft,
        saveTitle: String,
        isSaving: Bool,
        errorMessage: String?,
        showsDescriptorDraftFlow: Bool = false,
        onSave: @escaping (CronJobEditorDraft) async -> Bool
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.showsDescriptorDraftFlow = showsDescriptorDraftFlow
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if showsDescriptorDraftFlow {
                    Section("Describe It") {
                        TextField(
                            "e.g. Every weekday morning, summarize calendar and inbox",
                            text: $descriptor,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)

                        Button {
                            let suggestion = CronJobDraftSuggester.suggest(from: descriptor)
                            descriptor = suggestion.descriptor
                            descriptorSummary = suggestion.summary
                            draft = suggestion.draft
                        } label: {
                            Label("Suggest Values", systemImage: "sparkles")
                        }
                        .disabled(isSaving || descriptor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let descriptorSummary {
                            Text(descriptorSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Automation") {
                    TextField("Name", text: $draft.name)

                    TextField("Prompt", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)

                    TextField("Schedule", text: $draft.schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Delivery") {
                    TextField("Deliver", text: $draft.deliver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Toast Notifications", isOn: $draft.toastNotifications)
                }

                Section("Configuration") {
                    TextField("Skills", text: $draft.skillsText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model", text: $draft.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Profile", text: $draft.profile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
    }

    private var formMessage: String? {
        errorMessage ?? draft.validationMessage
    }

    private var messageColor: Color {
        errorMessage == nil ? .secondary : .red
    }
}

struct CronJobMetadataRow: View {
    let title: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    valueText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                        .frame(width: 64, alignment: .leading)
                    valueText
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}
