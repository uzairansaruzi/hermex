import SwiftUI

/// A server's scheduled Tasks. A webui server's comes from the session list's sidebar; a
/// Hermes host's from its inbox's + menu (#1040), where `client` is its `HermesCronClient`
/// and a new Task starts in `newTaskProfile`.
struct TasksView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    private let newTaskProfile: String?

    @State private var viewModel: TasksViewModel
    @State private var isPresentingCreateTask = false
    @State private var jobPendingDeletion: CronJob?
    /// A paused Task whose Run Now would also resume it, while the user is asked.
    @State private var jobPendingRunConfirmation: CronJob?
    /// Each row's Run Now on a Hermes host, which follows the run until the host's outcome
    /// (#1041). Leaving the screen cancels them, which stops the reads and leaves the runs to
    /// the host; the list read on return shows where they are.
    @State private var runNowTasks: [String: Task<Void, Never>] = [:]
    /// "Ran Recently" shows a few rows until the user asks for the rest. View
    /// state only: every fresh visit starts compact.
    @State private var isShowingAllRecentRuns = false

    /// Rows "Ran Recently" shows before it needs a "Show all" row.
    private static let compactRecentRunCount = 3

    init(
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        client: (any CronDataClient)? = nil,
        newTaskProfile: String? = nil
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.newTaskProfile = newTaskProfile
        _viewModel = State(initialValue: TasksViewModel(server: server, client: client))
    }

    private var features: CronFeatures { viewModel.client.cronFeatures }

    var body: some View {
        content
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearActionError()
                        isPresentingCreateTask = true
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .disabled(viewModel.isMutating)

                    Button {
                        Task { await loadTasks() }
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
            .sheet(isPresented: $isPresentingCreateTask, onDismiss: {
                // A failed create leaves its message behind; without this the
                // list's own alert would fire the moment the sheet closes.
                viewModel.clearActionError()
            }) {
                CronJobEditorSheet(
                    title: String(localized: "New Task"),
                    server: server,
                    draft: CronJobEditorDraft(profile: newTaskProfile ?? ""),
                    saveTitle: String(localized: "Create"),
                    isSaving: viewModel.isMutating,
                    errorMessage: viewModel.actionErrorMessage,
                    deliveryOptions: viewModel.deliveryOptions,
                    client: viewModel.client
                ) { draft in
                    let didCreate = await viewModel.create(from: draft)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didCreate
                }
            }
            .alert("Delete Task?", isPresented: deletionConfirmationBinding, presenting: jobPendingDeletion) { job in
                Button("Delete", role: .destructive) {
                    Task { await performAction { await viewModel.delete(job) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { job in
                Text("“\(job.displayName)” will be removed from the Hermes server.")
            }
            .alert("Run Now?", isPresented: runConfirmationBinding, presenting: jobPendingRunConfirmation) { job in
                Button("Run Now") { startRunNow(job) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This also resumes the Task.")
            }
            .alert("Could Not Update Task", isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) { viewModel.clearActionError() }
            } message: {
                Text(viewModel.actionErrorMessage ?? "")
            }
            .alert("Saved", isPresented: saveWarningBinding) {
                Button("OK", role: .cancel) { viewModel.clearSaveWarning() }
            } message: {
                Text(verbatim: viewModel.saveWarning ?? "")
            }
            .task {
                await loadTasks()
            }
            .onDisappear {
                runNowTasks.values.forEach { $0.cancel() }
                runNowTasks = [:]
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.jobs.isEmpty {
            ProgressView("Loading tasks...")
        } else if let errorMessage = viewModel.errorMessage, viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadTasks() }
                }
            }
        } else if viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label("No Tasks", systemImage: "calendar.badge.clock")
            } description: {
                Text("Scheduled jobs from the Hermes server will appear here.")
            }
        } else {
            agenda
        }
    }

    private var sections: [TaskAgendaSection] {
        viewModel.sections()
    }

    @ViewBuilder
    private var agenda: some View {
        Group {
            if sections.isEmpty && viewModel.recentRuns.isEmpty && viewModel.schedulerStallAge == nil {
                noMatchingTasks
            } else {
                // The list stays mounted while the feed has rows, so switching
                // to a filter with no tasks does not take "Ran Recently" away.
                List {
                    schedulerNotice
                    recentRunsSection

                    if sections.isEmpty {
                        Section {
                            noMatchingTasks
                                .listRowBackground(Color.clear)
                        }
                    }

                    ForEach(sections) { section in
                        Section(section.group.title) {
                            ForEach(section.jobs) { job in
                                row(for: job, in: section.group)
                            }
                        }
                    }
                }
                .refreshable {
                    await loadTasks()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filterPicker
        }
    }

    private var noMatchingTasks: some View {
        ContentUnavailableView {
            Label("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No tasks match this filter.")
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(TaskFilter.allCases) { filter in
                Text(filter.title(count: viewModel.count(for: filter))).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// One line when a Hermes host's scheduler has stopped ticking (#1040), above
    /// everything else and outside the filter, since no Task will fire until it is back.
    @ViewBuilder
    private var schedulerNotice: some View {
        if let age = viewModel.schedulerStallAge {
            let stalled = Duration.seconds(age).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide,
                                                                 maximumUnitCount: 2))
            Section {
                Label {
                    Text("Scheduled Tasks aren't running. The host's scheduler hasn't checked in for \(stalled).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }
        }
    }

    /// Cross-task recent completions, above the agenda and outside the filter.
    /// Absent until the feed answers and whenever it is empty or failed.
    @ViewBuilder
    private var recentRunsSection: some View {
        let recentRuns = viewModel.recentRuns
        if !recentRuns.isEmpty {
            let isTruncated = recentRuns.count > Self.compactRecentRunCount && !isShowingAllRecentRuns
            let visibleRuns = isTruncated ? Array(recentRuns.prefix(Self.compactRecentRunCount)) : recentRuns

            Section("Ran Recently") {
                ForEach(visibleRuns) { completion in
                    if let job = viewModel.job(for: completion) {
                        NavigationLink {
                            detail(for: job)
                        } label: {
                            TaskRecentRunRowView(completion: completion)
                        }
                    } else {
                        // The feed named a job the list does not have: no link,
                        // no chevron, and nothing that reads as a button.
                        TaskRecentRunRowView(completion: completion)
                    }
                }

                if recentRuns.count > Self.compactRecentRunCount {
                    Button {
                        isShowingAllRecentRuns.toggle()
                    } label: {
                        Text(isTruncated ? "Show All (\(recentRuns.count))" : "Show Less")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private func detail(for job: CronJob) -> some View {
        TaskDetailView(
            job: job,
            runningElapsed: viewModel.runningElapsed(for: job),
            server: server,
            client: viewModel.client,
            onAPIError: onAPIError,
            onMutation: { mutation in
                viewModel.apply(mutation)
            }
        )
    }

    private func row(for job: CronJob, in group: TaskAgendaGroup) -> some View {
        NavigationLink {
            detail(for: job)
        } label: {
            CronJobRowView(
                job: job,
                group: group,
                runningElapsed: viewModel.runningElapsed(for: job),
                profile: features.isProfileScoped ? job.profileLabel : nil
            )
        }
        .swipeActions(edge: .trailing) {
            pauseResumeButton(for: job)
            runNowButton(for: job)
        }
        .contextMenu {
            runNowButton(for: job)
            pauseResumeButton(for: job)

            Divider()

            Button(role: .destructive) {
                jobPendingDeletion = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        }
    }

    @ViewBuilder
    private func runNowButton(for job: CronJob) -> some View {
        if features.offersRunNow(for: job) {
            Button {
                if features.runNowResumes(job) {
                    jobPendingRunConfirmation = job
                } else {
                    startRunNow(job)
                }
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .tint(.blue)
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        }
    }

    @ViewBuilder
    private func pauseResumeButton(for job: CronJob) -> some View {
        if job.isLive {
            Button {
                Task { await performAction { await viewModel.pause(job) } }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .tint(.orange)
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        } else {
            Button {
                Task { await performAction { await viewModel.resume(job) } }
            } label: {
                Label("Resume", systemImage: "play.circle")
            }
            .tint(.green)
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        }
    }

    private func startRunNow(_ job: CronJob) {
        guard let jobID = job.jobId, runNowTasks[jobID] == nil else { return }
        let run = Task {
            await performAction { await viewModel.runNow(job) }
            if !Task.isCancelled { runNowTasks[jobID] = nil }
        }
        if features.runNowWaitsForRun {
            runNowTasks[jobID] = run
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { jobPendingDeletion != nil },
            set: { if !$0 { jobPendingDeletion = nil } }
        )
    }

    private var runConfirmationBinding: Binding<Bool> {
        Binding(
            get: { jobPendingRunConfirmation != nil },
            set: { if !$0 { jobPendingRunConfirmation = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionErrorMessage != nil && !isPresentingCreateTask },
            set: { if !$0 { viewModel.clearActionError() } }
        )
    }

    /// Shown once the create sheet has closed on the Task it saved.
    private var saveWarningBinding: Binding<Bool> {
        Binding(
            get: { viewModel.saveWarning != nil && !isPresentingCreateTask },
            set: { if !$0 { viewModel.clearSaveWarning() } }
        )
    }

    private func performAction(_ action: () async -> Void) async {
        await action()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadTasks() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
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
