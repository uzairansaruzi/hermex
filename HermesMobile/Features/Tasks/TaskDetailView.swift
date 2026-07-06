import SwiftUI

struct TaskDetailView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onMutation: (CronJobListMutation) -> Void

    @State private var viewModel: TaskDetailViewModel
    @State private var isPresentingEditTask = false
    @State private var isConfirmingDelete = false
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
                headerSection
                actionStatusSection
                metadataSection

                if viewModel.isLoading && viewModel.outputs.isEmpty {
                    ProgressView("Loading output...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else if let errorMessage = viewModel.errorMessage, viewModel.outputs.isEmpty {
                    ContentUnavailableView {
                        Label("Could Not Load Output", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadOutput() }
                        }
                    }
                    .padding(.top, 24)
                } else if viewModel.outputs.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Output", systemImage: "doc.text")
                    } description: {
                        Text("This task has not produced any output yet.")
                    }
                    .padding(.top, 24)
                } else {
                    outputsSection
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.job.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await loadOutput() }
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
        .sheet(isPresented: $isPresentingEditTask) {
            CronJobEditorSheet(
                title: String(localized: "Edit Task"),
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
        .alert("Delete Task?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scheduled task from the Hermes server.")
        }
        .task {
            await loadOutput()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(viewModel.job.displayName)
                    .font(.title2.bold())
                    .lineLimit(2)

                Spacer(minLength: 8)

                StatusBadge(
                    text: viewModel.runningElapsed == nil ? viewModel.job.status.label : String(localized: "Running"),
                    color: statusColor
                )
            }

            if let prompt = viewModel.job.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
    }

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
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            CronJobMetadataRow(
                title: String(localized: "Schedule"),
                value: viewModel.job.scheduleText ?? String(localized: "Not available")
            )

            CronJobMetadataRow(
                title: String(localized: "Next"),
                value: viewModel.job.nextRunAt?.formatted ?? String(localized: "Not available")
            )

            CronJobMetadataRow(
                title: String(localized: "Last"),
                value: viewModel.job.lastRunAt?.formatted ?? String(localized: "Never")
            )

            if let runningElapsed = viewModel.runningElapsed {
                CronJobMetadataRow(
                    title: String(localized: "Elapsed"),
                    value: elapsedText(runningElapsed)
                )
            }

            CronJobMetadataRow(
                title: String(localized: "Deliver"),
                value: viewModel.job.deliver ?? "local"
            )

            if let model = viewModel.job.model, !model.isEmpty {
                CronJobMetadataRow(title: String(localized: "Model"), value: model)
            }

            if let provider = viewModel.job.provider, !provider.isEmpty {
                CronJobMetadataRow(title: String(localized: "Provider"), value: provider)
            }

            if let profile = viewModel.job.profile, !profile.isEmpty {
                CronJobMetadataRow(title: String(localized: "Profile"), value: profile)
            }

            if let toastNotifications = viewModel.job.toastNotifications {
                CronJobMetadataRow(title: String(localized: "Toasts"), value: toastNotifications ? String(localized: "On") : String(localized: "Off"))
            }

            if let skills = viewModel.job.skills, !skills.isEmpty {
                CronJobMetadataRow(title: String(localized: "Skills"), value: skills.joined(separator: ", "))
            }

            if let error = viewModel.job.lastError ?? viewModel.job.lastDeliveryError, !error.isEmpty {
                CronJobMetadataRow(title: String(localized: "Error"), value: error)
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Output")
                .font(.headline)

            ForEach(viewModel.outputs) { output in
                VStack(alignment: .leading, spacing: 8) {
                    Text(output.filename ?? String(localized: "Untitled"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let content = output.content, !content.isEmpty {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text("Empty output")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var statusColor: Color {
        if viewModel.runningElapsed != nil {
            return .blue
        }

        switch viewModel.job.status {
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

    private func elapsedText(_ elapsed: Double) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed.rounded()))s"
        }

        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    private func loadOutput() async {
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
