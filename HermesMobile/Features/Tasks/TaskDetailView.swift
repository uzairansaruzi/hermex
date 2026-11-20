import SwiftUI

struct TaskDetailView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onMutation: (CronJobListMutation) -> Void

    @State private var viewModel: TaskDetailViewModel
    @State private var isPresentingEditTask = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingRunNow = false
    @State private var runNowTask: Task<Void, Never>?
    @State private var selectedRun: CronRunHistoryItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        job: CronJob,
        runningElapsed: Double?,
        server: URL,
        client: (any CronDataClient)? = nil,
        onAPIError: @escaping (Error) -> Void,
        onMutation: @escaping (CronJobListMutation) -> Void = { _ in }
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.onMutation = onMutation
        _viewModel = State(initialValue: TaskDetailViewModel(
            job: job, runningElapsed: runningElapsed, server: server, client: client
        ))
    }

    private var features: CronFeatures { viewModel.client.cronFeatures }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TaskDetailHeaderCard(
                    job: viewModel.job,
                    runningElapsed: viewModel.runningElapsed,
                    isBusy: isActionDisabled,
                    canSeeFullOutput: viewModel.latestRun != nil,
                    showsRunNow: features.offersRunNow(for: viewModel.job),
                    runNowState: viewModel.runNowState,
                    runNow: requestRunNow,
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
                        outcome: viewModel.outcome,
                        selectRun: open,
                        retry: { Task { await viewModel.loadHistory() } },
                        loadMore: { Task { await viewModel.loadMoreRuns() } }
                    )
                }
            }
            .padding()
        }
        .themedPageBackground()
        .navigationTitle(viewModel.job.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadDetail() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPresentingEditTask, onDismiss: viewModel.clearActionError) {
            CronJobEditorSheet(
                title: String(localized: "Edit Task"),
                server: server,
                draft: CronJobEditorDraft(job: viewModel.job),
                saveTitle: String(localized: "Save"),
                isSaving: viewModel.isMutating,
                errorMessage: viewModel.actionErrorMessage,
                deliveryOptions: viewModel.deliveryOptions,
                client: viewModel.client,
                locksProfile: features.isProfileScoped
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
        .alert("Run Now?", isPresented: $isConfirmingRunNow) {
            Button("Run Now", action: startRunNow)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also resumes the Task.")
        }
        .task {
            await loadDetail()
        }
        .onDisappear {
            runNowTask?.cancel()
            runNowTask = nil
        }
    }

    @ViewBuilder
    private var actionStatusSection: some View {
        if viewModel.isMutating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating task...")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
        } else if let actionErrorMessage = viewModel.actionErrorMessage {
            Text(actionErrorMessage)
                .font(AppFont.footnote())
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var promptCard: some View {
        if let prompt = viewModel.job.prompt, !prompt.isEmpty {
            SectionCard(title: String(localized: "Prompt")) {
                Text(prompt)
                    .font(AppFont.callout())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

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

    private var configurationCard: some View {
        let fields = TaskConfigurationField.fields(for: viewModel.job)

        return SectionCard(title: String(localized: "Configuration")) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
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
            .font(AppFont.footnote())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configurationLabel(_ field: TaskConfigurationField) -> some View {
        Text(field.title)
            .foregroundStyle(.appSecondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func configurationValue(_ field: TaskConfigurationField) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(field.value)
                .foregroundStyle(.appPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 3)

            if let detail = field.detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.appTertiary)
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
                if features.offersRunNow(for: viewModel.job) {
                    Button(action: requestRunNow) {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .disabled(isActionDisabled || viewModel.runNowState != .idle)
                }

                Button {
                    Task { await togglePauseResume() }
                } label: {
                    Label(viewModel.job.pauseResumeTitle, systemImage: viewModel.job.pauseResumeSystemImage)
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

    private var isActionDisabled: Bool {
        viewModel.isMutating || viewModel.job.jobId == nil
    }

    private func open(_ run: CronRunHistoryItem) {
        selectedRun = run
        Task { await viewModel.loadRunOutput(for: run) }
    }

    private func loadDetail() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
        if let mutation = viewModel.lastMutation {
            onMutation(mutation)
        }
    }

    private func requestRunNow() {
        if features.runNowResumes(viewModel.job) {
            isConfirmingRunNow = true
        } else {
            startRunNow()
        }
    }

    private func startRunNow() {
        guard runNowTask == nil else { return }
        let run = Task {
            let didRun = await viewModel.runNow()
            guard !Task.isCancelled else { return }
            runNowTask = nil
            handleActionResult(didRun)
        }
        if features.runNowWaitsForRun {
            runNowTask = run
        }
    }

    private func togglePauseResume() async {
        let didMutate: Bool
        if viewModel.job.shouldResume {
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
