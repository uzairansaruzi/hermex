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

                if let relatedSession = viewModel.relatedSession {
                    relatedSessionSection(relatedSession)
                }

                if hasRecentRunContent {
                    recentRunsSection
                } else if viewModel.isLoading {
                    ProgressView("Loading runs...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Could Not Load Runs", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadOutput() }
                        }
                    }
                    .padding(.top, 24)
                } else {
                    ContentUnavailableView {
                        Label("No Recent Runs", systemImage: "doc.text")
                    } description: {
                        Text("This automation has not produced any output yet.")
                    }
                    .padding(.top, 24)
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
                    Label("Automation Actions", systemImage: "ellipsis.circle")
                }
                .disabled(viewModel.isMutating)
            }
        }
        .sheet(isPresented: $isPresentingEditTask) {
            CronJobEditorSheet(
                title: String(localized: "Edit Automation"),
                draft: CronJobEditorDraft(job: viewModel.job),
                saveTitle: String(localized: "Save"),
                isSaving: viewModel.isMutating,
                errorMessage: viewModel.actionErrorMessage
            ) { draft in
                let didUpdate = await viewModel.update(from: draft)
                handleActionResult(didUpdate)
                return didUpdate
            }
        }
        .alert("Delete Automation?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scheduled automation from the Hermes server.")
        }
        .task {
            await loadOutput()
        }
        .zoraBrandedScreen()
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
                Text("Updating automation...")
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

    private func relatedSessionSection(_ relatedSession: CronRelatedSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related Chat")
                .font(.headline)

            NavigationLink {
                ChatView(
                    session: relatedSession.sessionSummary(profile: viewModel.job.profile),
                    server: server,
                    onAPIError: onAPIError
                )
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(ZoraBrand.selectionAccent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(relatedSession.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let messageCount = relatedSession.messageCount {
                            Text("\(messageCount) messages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Open the chat created by the latest automation run")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(ZoraBrand.subtleFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ZoraBrand.surfaceHairline, lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Runs")
                .font(.headline)

            ForEach(viewModel.recentRunItems) { item in
                NavigationLink {
                    CronRunOutputDetailView(item: item)
                } label: {
                    CronRunListRow(item: item)
                }
                .buttonStyle(.plain)
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

    private var hasRecentRunContent: Bool {
        !viewModel.recentRunItems.isEmpty
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

private struct CronRunListRow: View {
    let item: CronRunListItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.hasOutputContent ? "doc.text.fill" : "doc.text")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoraBrand.subtleFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ZoraBrand.surfaceHairline, lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayTitle)
        .accessibilityHint("Opens run output.")
    }
}

private struct CronRunOutputDetailView: View {
    let item: CronRunListItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection
                outputSection
            }
            .padding()
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var metadataSection: some View {
        let hasMetadata = item.modified != nil || item.size != nil || item.usage != nil

        if hasMetadata {
            VStack(alignment: .leading, spacing: 6) {
                if let modified = item.modified {
                    CronJobMetadataRow(
                        title: String(localized: "Modified"),
                        value: Date(timeIntervalSince1970: modified).formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let size = item.size {
                    CronJobMetadataRow(
                        title: String(localized: "Size"),
                        value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    )
                }

                if let usage = item.usage {
                    if let duration = usage.durationSeconds {
                        CronJobMetadataRow(title: String(localized: "Duration"), value: durationText(duration))
                    }

                    if let totalTokens = usage.totalTokens {
                        CronJobMetadataRow(title: String(localized: "Tokens"), value: "\(totalTokens)")
                    }

                    if let model = nonEmpty(usage.model) {
                        CronJobMetadataRow(title: String(localized: "Model"), value: model)
                    }

                    if let provider = nonEmpty(usage.provider) {
                        CronJobMetadataRow(title: String(localized: "Provider"), value: provider)
                    }

                    if let cost = usage.estimatedCostUSD {
                        CronJobMetadataRow(title: String(localized: "Cost"), value: cost.formatted(.currency(code: "USD")))
                    }
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.headline)

            if let content = nonEmpty(item.outputContent) {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZoraBrand.codeBlockFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ZoraBrand.codeBlockStroke, lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
            } else {
                ContentUnavailableView {
                    Label("No Output", systemImage: "doc.text")
                } description: {
                    Text("No output content was returned for this run.")
                }
            }
        }
    }

    private func durationText(_ duration: Double) -> String {
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }

        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
