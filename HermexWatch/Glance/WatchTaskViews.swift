import SwiftUI
import HermexWatchRoot
import WatchShared

// MARK: - Tasks

/// "Is anything scheduled running or failing?" Running first, then scheduled,
/// then switched off. Run / Pause / Resume are one swipe away; the detail
/// screen adds when it runs next, how the last run went, and recent output.
struct WatchTaskListView: View {
    @Bindable var model: WatchRootModel
    @State private var tasks: [WatchTaskSummary] = []
    @State private var phase: WatchGlancePhase = .loading
    @State private var actionError: String?

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: tasks.isEmpty,
                emptyTitle: "No scheduled tasks",
                emptySymbol: "clock",
                retry: reload
            )
            if let actionError {
                WatchActionErrorRow(message: actionError)
            }
            ForEach(sortedTasks, id: \.key) { task in
                NavigationLink {
                    WatchTaskDetailView(model: model, task: task) {
                        await reload()
                    }
                } label: {
                    taskRow(task)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        Task { await control(task, .run) }
                    } label: {
                        Label("Run now", systemImage: "play.fill")
                    }
                    .tint(.green)
                    .disabled(!model.canMutate || task.running)
                }
                .swipeActions(edge: .leading) {
                    if task.enabled {
                        Button {
                            Task { await control(task, .pause) }
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .tint(.orange)
                        .disabled(!model.canMutate)
                    } else {
                        Button {
                            Task { await control(task, .resume) }
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .tint(.blue)
                        .disabled(!model.canMutate)
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var sortedTasks: [WatchTaskSummary] {
        tasks.sorted { lhs, rhs in
            let left = WatchTaskPresentation.rank(lhs), right = WatchTaskPresentation.rank(rhs)
            if left != right { return left < right }
            return (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
        }
    }

    private func taskRow(_ task: WatchTaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.name)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let badge = WatchTaskPresentation.badge(for: task) {
                    WatchStatusBadge(text: badge.text, tint: badge.tint)
                }
                Text(task.schedule)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if WatchTaskPresentation.lastRunFailed(task), let failure = task.failureSummary ?? task.lastResult {
                Label(failure, systemImage: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if !task.running, task.enabled, let next = task.nextRunAt {
                HStack(spacing: 3) {
                    Text("Next")
                    WatchRelativeDate(date: next)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(task.enabled || task.running ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens schedule, last run and Run now. Swipe for Run now, Pause or Resume.")
    }

    private func control(_ task: WatchTaskSummary, _ action: TaskControl) async {
        actionError = nil
        if await model.controlTask(jobID: task.key.jobID, action: action, scope: task.key.scope) {
            WatchHaptics.play(.success)
            await reload()
        } else {
            actionError = WatchTaskPresentation.failureCopy(for: action)
            WatchHaptics.play(.failure)
        }
    }

    private func reload() async {
        if tasks.isEmpty { phase = .loading }
        let loaded = await model.loadTasks()
        phase = .after(model)
        // A failed refresh keeps the rows already on screen.
        if phase == .loaded { tasks = loaded }
    }
}

/// Shared wording and colour for task state, so the list row and the detail
/// screen never disagree.
enum WatchTaskPresentation {
    static func rank(_ task: WatchTaskSummary) -> Int {
        if task.running { return 0 }
        if lastRunFailed(task) { return 1 }
        return task.enabled ? 2 : 3
    }

    static func lastRunFailed(_ task: WatchTaskSummary) -> Bool {
        guard !task.running else { return false }
        if task.failureSummary != nil, task.lastResult?.lowercased() != "ok" { return true }
        let lowered = task.lastResult?.lowercased() ?? ""
        return ["error", "fail", "timeout", "timed out"].contains { lowered.contains($0) }
    }

    static func badge(for task: WatchTaskSummary) -> (text: String, tint: Color)? {
        if task.running { return ("Running", .orange) }
        if lastRunFailed(task) { return ("Failed", .red) }
        if !task.enabled { return ("Paused", .gray) }
        return nil
    }

    static func failureCopy(for action: TaskControl) -> String {
        switch action {
        case .run: return "Couldn’t start that task."
        case .pause: return "Couldn’t pause that task."
        case .resume: return "Couldn’t resume that task."
        }
    }
}

// MARK: - Task detail

struct WatchTaskDetailView: View {
    @Bindable var model: WatchRootModel
    let onChange: () async -> Void
    @State private var task: WatchTaskSummary
    @State private var busy: TaskControl?
    @State private var actionError: String?
    @State private var runs: [WatchTaskRun] = []
    @State private var runsPhase: WatchGlancePhase = .loading

    init(model: WatchRootModel, task: WatchTaskSummary, onChange: @escaping () async -> Void) {
        self.model = model
        self.onChange = onChange
        _task = State(initialValue: task)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.headline)
                    if let badge = WatchTaskPresentation.badge(for: task) {
                        WatchStatusBadge(text: badge.text, tint: badge.tint)
                    }
                }
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)

                if let actionError {
                    WatchActionErrorRow(message: actionError)
                }

                // Primary action first, full width.
                Button {
                    Task { await run(.run) }
                } label: {
                    actionLabel("Run now", systemImage: "play.fill", action: .run)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(busy != nil || !model.canMutate || task.running)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .accessibilityHint(task.running ? "Already running." : "Starts this task once now.")

                Button {
                    Task { await run(task.enabled ? .pause : .resume) }
                } label: {
                    actionLabel(
                        task.enabled ? "Pause" : "Resume",
                        systemImage: task.enabled ? "pause.fill" : "play.circle",
                        action: task.enabled ? .pause : .resume
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(busy != nil || !model.canMutate)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .accessibilityHint(task.enabled ? "Stops future scheduled runs." : "Turns the schedule back on.")
            }

            Section {
                WatchFactRow(title: "Schedule", systemImage: "clock") {
                    Text(task.schedule)
                }
                if task.enabled, let next = task.nextRunAt {
                    WatchFactRow(title: "Next run", systemImage: "calendar") {
                        WatchRelativeDate(date: next)
                    }
                }
                if let last = task.lastRunAt {
                    WatchFactRow(title: "Last run", systemImage: "clock.arrow.circlepath") {
                        WatchRelativeDate(date: last)
                    }
                }
                if WatchTaskPresentation.lastRunFailed(task) {
                    Label(task.failureSummary ?? task.lastResult ?? "Last run failed", systemImage: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if task.lastResult?.lowercased() == "ok" {
                    Label("Last run OK", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Section {
                WatchGlanceStatusRows(
                    phase: runsPhase,
                    isEmpty: runs.isEmpty,
                    emptyTitle: "No runs yet",
                    emptySymbol: "clock.arrow.circlepath",
                    retry: loadRuns
                )
                ForEach(runs, id: \.runID) { run in
                    NavigationLink {
                        WatchTaskRunOutputView(model: model, run: run)
                    } label: {
                        runRow(run)
                    }
                    .accessibilityIdentifier("taskRun")
                }
            } header: {
                Text("Recent runs")
            } footer: {
                Text("Editing the prompt or schedule stays on iPhone.")
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRuns() }
    }

    private func actionLabel(_ title: String, systemImage: String, action: TaskControl) -> some View {
        HStack(spacing: 6) {
            if busy == action {
                ProgressView()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 28)
    }

    private func runRow(_ run: WatchTaskRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let finished = run.finishedAt {
                WatchRelativeDate(date: finished)
                    .font(.footnote)
            } else {
                Text("Run")
                    .font(.footnote)
            }
            if let started = run.startedAt, let finished = run.finishedAt {
                Text(Duration.seconds(finished.timeIntervalSince(started)), format: .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this run’s output.")
    }

    private func loadRuns() async {
        if runs.isEmpty { runsPhase = .loading }
        if let loaded = await model.loadTaskRuns(jobID: task.key.jobID) {
            runs = loaded
            runsPhase = .loaded
        } else {
            runsPhase = .failed("Couldn’t load recent runs.")
        }
    }

    private func run(_ action: TaskControl) async {
        busy = action
        actionError = nil
        defer { busy = nil }
        guard await model.controlTask(jobID: task.key.jobID, action: action, scope: task.key.scope) else {
            actionError = WatchTaskPresentation.failureCopy(for: action)
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        // Show the server's state, not a guess: reload and adopt this task's row.
        if let updated = await model.loadTasks().first(where: { $0.key == task.key }) {
            task = updated
        }
        await onChange()
        if action == .run { await loadRuns() }
    }
}

// MARK: - Run output

struct WatchTaskRunOutputView: View {
    let model: WatchRootModel
    let run: WatchTaskRun
    @State private var detail: WatchTaskRunDetail?
    @State private var phase: WatchGlancePhase = .loading

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: detail?.output == nil,
                emptyTitle: "This run produced no output",
                emptySymbol: "doc.text",
                retry: load
            )
            if let output = detail?.output {
                WatchMarkdownText(text: output)
                    .listRowBackground(Color.clear)
                if detail?.outputTruncated == true {
                    Text("Shortened for the wrist. Full output on iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Output")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        if let loaded = await model.loadTaskRunOutput(jobID: run.task.jobID, runID: run.runID) {
            detail = loaded
            phase = .loaded
        } else {
            phase = .failed("Couldn’t load this run’s output.")
        }
    }
}
