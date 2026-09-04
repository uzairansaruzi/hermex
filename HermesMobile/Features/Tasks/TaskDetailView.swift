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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Everything the list row deliberately stopped showing.
    ///
    /// Laid out as a grid so the label column takes the width of its widest
    /// label. A fixed column has to guess, and guesses low: "Notifications"
    /// wrapped onto three lines against the 64pt the old rows used.
    private var configurationCard: some View {
        let fields = TaskConfigurationField.fields(for: viewModel.job)

        return SectionCard(title: String(localized: "Configuration")) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // At accessibility sizes two columns leave no room for
                    // either, so the label sits above its value instead.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 1) {
                                configurationLabel(field)
                                configurationValue(field)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(fields) { field in
                            GridRow {
                                configurationLabel(field)
                                    .gridColumnAlignment(.leading)
                                configurationValue(field)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configurationLabel(_ field: TaskConfigurationField) -> some View {
        Text(field.title)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func configurationValue(_ field: TaskConfigurationField) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(field.value)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 3)

            if let detail = field.detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
