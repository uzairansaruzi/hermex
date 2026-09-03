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
            .sheet(isPresented: $isPresentingCreateTask) {
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
            List {
                Section {
                    HStack {
                        Label("Running now", systemImage: "bolt.fill")
                        Spacer()
                        Text("\(viewModel.activeRunningCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Scheduled Jobs") {
                    ForEach(viewModel.jobs) { job in
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
                        }
                    }
                }
            }
            .refreshable {
                await loadTasks()
            }
        }
    }

    private func loadTasks() async {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(2)

                Spacer(minLength: 8)

                StatusBadge(
                    text: runningElapsed == nil ? job.status.label : String(localized: "Running"),
                    color: statusColor
                )
            }

            if let prompt = job.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 6) {
                CronJobMetadataRow(
                    title: String(localized: "Schedule"),
                    value: job.scheduleText ?? String(localized: "Not available")
                )

                CronJobMetadataRow(
                    title: String(localized: "Next"),
                    value: job.nextRunAt?.formatted ?? String(localized: "Not available")
                )

                CronJobMetadataRow(
                    title: String(localized: "Last"),
                    value: job.lastRunAt?.formatted ?? String(localized: "Never")
                )

                if let runningElapsed {
                    CronJobMetadataRow(
                        title: String(localized: "Elapsed"),
                        value: Self.elapsedText(runningElapsed)
                    )
                }

                CronJobMetadataRow(
                    title: String(localized: "Deliver"),
                    value: job.deliver ?? "local"
                )

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

                if let error = job.lastError ?? job.lastDeliveryError, !error.isEmpty {
                    CronJobMetadataRow(title: String(localized: "Error"), value: error)
                        .foregroundStyle(.red)
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
