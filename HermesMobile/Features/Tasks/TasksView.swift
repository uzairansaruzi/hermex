import SwiftUI

struct TasksView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: TasksViewModel
    @State private var isPresentingCreateTask = false
    @State private var jobPendingDeletion: CronJob?

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: TasksViewModel(server: server))
    }

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
                    draft: CronJobEditorDraft(),
                    saveTitle: String(localized: "Create"),
                    isSaving: viewModel.isMutating,
                    errorMessage: viewModel.actionErrorMessage,
                    deliveryOptions: viewModel.deliveryOptions
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
            .alert("Could Not Update Task", isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) { viewModel.clearActionError() }
            } message: {
                Text(viewModel.actionErrorMessage ?? "")
            }
            .task {
                await loadTasks()
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
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No tasks match this filter.")
                }
            } else {
                List {
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

    private func row(for job: CronJob, in group: TaskAgendaGroup) -> some View {
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
                group: group,
                runningElapsed: viewModel.runningElapsed(for: job)
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
            .disabled(job.jobId == nil)
        }
    }

    @ViewBuilder
    private func runNowButton(for job: CronJob) -> some View {
        Button {
            Task { await performAction { await viewModel.runNow(job) } }
        } label: {
            Label("Run Now", systemImage: "play.fill")
        }
        .tint(.blue)
        .disabled(job.jobId == nil || viewModel.isPendingAction(job))
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

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { jobPendingDeletion != nil },
            set: { if !$0 { jobPendingDeletion = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionErrorMessage != nil && !isPresentingCreateTask },
            set: { if !$0 { viewModel.clearActionError() } }
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
