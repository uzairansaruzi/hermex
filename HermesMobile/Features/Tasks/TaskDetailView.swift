import SwiftUI

/// Task Detail: what the task is, when it runs next, how it is configured, and
/// — the part the list cannot answer — what it has actually been doing.
struct TaskDetailView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onMutation: (CronJobListMutation) -> Void

    @State private var viewModel: TaskDetailViewModel
    @State private var isPresentingEditTask = false
    @State private var isConfirmingDelete = false
    /// Sheet identity lives here so the sheet is always tied to the run that was
    /// tapped; the view model only fetches its text.
    @State private var selectedRun: CronRunHistoryItem?
    @Environment(\.dismiss) private var dismiss

    init(
        job: CronJob,
        runningElapsed: Double?,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        onMutation: @escaping (CronJobListMutation) -> Void = { _ in }
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.onMutation = onMutation
        _viewModel = State(initialValue: TaskDetailViewModel(job: job, runningElapsed: runningElapsed, server: server))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TaskDetailHeaderCard(
                    job: viewModel.job,
                    runningElapsed: viewModel.runningElapsed,
                    isBusy: isActionDisabled,
                    canSeeFullOutput: viewModel.latestRun != nil,
                    runNow: { Task { await runNow() } },
                    togglePauseResume: { Task { await togglePauseResume() } },
                    seeFullOutput: {
                        if let latest = viewModel.latestRun { open(latest) }
                    }
                )

                actionStatusSection
                promptCard
                latestOutputCard
                configurationCard

                if !viewModel.isHistoryUnavailable {
                    TaskRunHistorySection(
                        runs: viewModel.runs,
                        total: viewModel.runTotal,
                        isLoading: viewModel.isLoadingHistory,
                        isLoadingMore: viewModel.isLoadingMoreRuns,
                        canLoadMore: viewModel.canLoadMoreRuns,
                        remainingCount: viewModel.remainingRunCount,
                        errorMessage: viewModel.historyErrorMessage,
                        isFailedRun: viewModel.isFailedRun,
                        selectRun: open,
                        retry: { Task { await viewModel.loadHistory() } },
                        loadMore: { Task { await viewModel.loadMoreRuns() } }
                    )
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.job.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadDetail() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPresentingEditTask) {
            CronJobEditorSheet(
                title: String(localized: "Edit Task"),
                server: server,
                draft: CronJobEditorDraft(job: viewModel.job),
                saveTitle: String(localized: "Save"),
                isSaving: viewModel.isMutating,
                errorMessage: viewModel.actionErrorMessage,
                deliveryOptions: viewModel.deliveryOptions
            ) { draft in
                let didUpdate = await viewModel.update(from: draft)
                handleActionResult(didUpdate)
                return didUpdate
            }
        }
        .sheet(item: $selectedRun, onDismiss: viewModel.clearRunOutput) { run in
            TaskRunOutputSheet(
                run: run,
                output: viewModel.runOutput,
                isLoading: viewModel.isLoadingRunOutput,
                errorMessage: viewModel.runOutputErrorMessage,
                retry: { Task { await viewModel.loadRunOutput(for: run) } }
            )
        }
        .alert("Delete Task?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scheduled task from the Hermes server.")
        }
        .task {
            await loadDetail()
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var actionStatusSection: some View {
        if viewModel.isMutating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating task...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let actionErrorMessage = viewModel.actionErrorMessage {
            Text(actionErrorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var promptCard: some View {
        if let prompt = viewModel.job.prompt, !prompt.isEmpty {
            SectionCard(title: String(localized: "Prompt")) {
                Text(prompt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The last run's text, inline.
    ///
    /// Shown when the last run failed — a failure is the one case where the
    /// output is the point of the screen — and also when this server has no
    /// history endpoint, so an older server keeps the only view of its output
    /// it ever had.
    @ViewBuilder
    private var latestOutputCard: some View {
        if viewModel.job.hasFailedRun || viewModel.isHistoryUnavailable,
           let output = viewModel.outputs.first,
           let content = output.content,
           !content.isEmpty {
            SectionCard(title: String(localized: "Run Output")) {
                Text(content.strippingANSIEscapes())
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Everything the list row deliberately stopped showing. A field the server
    /// did not send is absent, not rendered as "Not available".
    private var configurationCard: some View {
        let job = viewModel.job

        return SectionCard(title: String(localized: "Configuration")) {
            VStack(alignment: .leading, spacing: 8) {
                CronJobMetadataRow(
                    title: String(localized: "Schedule"),
                    value: job.scheduleDescription?.sentence ?? job.scheduleText ?? String(localized: "Not available"),
                    detail: job.editableScheduleText
                )

                if let deliver = job.deliver, !deliver.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Deliver"), value: deliver)
                }

                if let model = job.model, !model.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Model"), value: model)
                }

                if let provider = job.provider, !provider.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Provider"), value: provider)
                }

                if let profile = job.profile, !profile.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Profile"), value: profile)
                }

                if let skills = job.skills, !skills.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Skills"), value: skills.joined(separator: ", "))
                }

                if let toastNotifications = job.toastNotifications {
                    CronJobMetadataRow(
                        title: String(localized: "Toast Notifications"),
                        value: toastNotifications ? String(localized: "On") : String(localized: "Off")
                    )
                }
            }
            .font(.footnote)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await loadDetail() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isLoading)

            Menu {
                Button {
                    Task { await runNow() }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(isActionDisabled)

                Button {
                    Task { await togglePauseResume() }
                } label: {
                    Label(pauseResumeTitle, systemImage: pauseResumeSystemImage)
                }
                .disabled(isActionDisabled)

                Button {
                    viewModel.clearActionError()
                    isPresentingEditTask = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(isActionDisabled)

                Divider()

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isActionDisabled)
            } label: {
                Label("Task Actions", systemImage: "ellipsis.circle")
            }
            .disabled(viewModel.isMutating)
        }
    }

    // MARK: - State

    private var isActionDisabled: Bool {
        viewModel.isMutating || viewModel.job.jobId == nil
    }

    private var pauseResumeTitle: String {
        shouldResume ? String(localized: "Resume") : String(localized: "Pause")
    }

    private var pauseResumeSystemImage: String {
        shouldResume ? "play.circle" : "pause.circle"
    }

    private var shouldResume: Bool {
        viewModel.job.status == .paused || viewModel.job.status == .off
    }

    // MARK: - Actions

    private func open(_ run: CronRunHistoryItem) {
        selectedRun = run
        Task { await viewModel.loadRunOutput(for: run) }
    }

    private func loadDetail() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func runNow() async {
        let didRun = await viewModel.runNow()
        handleActionResult(didRun)
    }

    private func togglePauseResume() async {
        let didMutate: Bool
        if shouldResume {
            didMutate = await viewModel.resume()
        } else {
            didMutate = await viewModel.pause()
        }
        handleActionResult(didMutate)
    }

    private func deleteTask() async {
        let didDelete = await viewModel.delete()
        handleActionResult(didDelete)

        if didDelete {
            dismiss()
        }
    }

    private func handleActionResult(_ success: Bool) {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        guard success, let mutation = viewModel.lastMutation else {
            return
        }

        onMutation(mutation)
    }
}
