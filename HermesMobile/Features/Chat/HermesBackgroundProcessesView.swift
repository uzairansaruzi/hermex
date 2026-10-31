import SwiftUI

/// A Hermes chat's toolbar entry to its background processes (#1420): its own glass button
/// beside the action cluster, `cpu` and the running count, shown while the session has rows
/// to inspect — running or recently finished.
struct HermesBackgroundProcessesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        ChatToolbarActionCluster {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(min(count, 99), format: .number)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Background processes, \(count) running")
            .accessibilityHint(Text("Shows this session's background commands, their output, and Stop controls."))
        }
    }
}

@MainActor struct HermesBackgroundProcessesView: View {
    let processes: HermesBackgroundProcesses
    @Environment(\.dismiss) private var dismiss
    @State private var stopAction: HermesBackgroundProcesses.StopAction?
    @State private var expandedTails: Set<HermesBackgroundProcess.Identity> = []

    var body: some View {
        NavigationStack {
            List {
                if let error = processes.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if processes.processes.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No background processes", systemImage: "cpu")
                        } description: {
                            Text(processes.isRefreshing
                                 ? "Refreshing background processes…"
                                 : "Processes appear here while the agent runs background commands in this session.")
                        }
                    }
                } else {
                    Section {
                        ForEach(processes.processes) { process in
                            processRow(process)
                        }
                    } header: {
                        Text("Background processes")
                    } footer: {
                        if processes.omittedProcessCount > 0 {
                            Text("Showing the first \(HermesBackgroundProcesses.maximumProcesses) processes. \(processes.omittedProcessCount) more are listed.")
                        } else {
                            Text("Output is limited to the latest 16 KB.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Background processes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await processes.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(processes.isRefreshing)
                    .accessibilityLabel("Refresh background processes")
                }
            }
            .refreshable { await processes.refresh() }
            .confirmationDialog(
                stopTitle,
                isPresented: Binding(
                    get: { stopAction != nil },
                    set: { if !$0 { stopAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = stopAction {
                    Button("Stop process", role: .destructive) {
                        stopAction = nil
                        Task { await processes.stop(action) }
                    }
                }
            } message: {
                Text("This stops the background command on the server. It cannot be resumed, and its remaining output is lost.")
            }
        }
    }

    private var stopTitle: String {
        guard let identity = stopAction?.process,
              let process = processes.processes.first(where: { $0.id == identity }) else {
            return String(localized: "Stop this process?")
        }
        return String(localized: "Stop “\(process.command ?? process.processID)”?")
    }

    @ViewBuilder
    private func processRow(_ process: HermesBackgroundProcess) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(process.command ?? String(localized: "Background process"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                Spacer(minLength: 8)
                if process.isFinished {
                    Text("Finished")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                } else {
                    Text((process.status ?? String(localized: "Running")).localizedUppercase)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if let pid = process.pid {
                    Label(String(pid), systemImage: "number")
                }
                if let uptime = uptimeText(process) {
                    Label(uptime, systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let result = processes.result, result.process == process.id {
                resultView(result)
            } else if let tail = process.tail, expandedTails.contains(process.id) {
                tailView(tail, truncated: process.tailTruncated)
            }

            if let result = processes.result, result.process == process.id {
                // The outcome replaced the row's controls.
            } else if processes.stoppingProcess == process.id {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Stopping…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    if let tail = process.tail {
                        Button(expandedTails.contains(process.id) ? "Hide output" : "Show output") {
                            if expandedTails.contains(process.id) {
                                expandedTails.remove(process.id)
                            } else {
                                expandedTails.insert(process.id)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if process.isStoppable {
                        Button("Stop", role: .destructive) {
                            stopAction = processes.prepareStop(process)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func uptimeText(_ process: HermesBackgroundProcess) -> String? {
        if let uptime = process.uptime { return uptime }
        guard let seconds = process.uptimeSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }

    @ViewBuilder
    private func resultView(_ result: HermesBackgroundProcessResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(result.isKilled ? String(localized: "Process stopped.") : String(localized: "This process had already exited."),
                  systemImage: result.isKilled ? "stop.circle" : "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let exitCode = result.exitCode {
                Text("Exit code \(exitCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let output = result.output, !output.isEmpty {
                ScrollView(.vertical) {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func tailView(_ tail: String, truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                Text(tail.isEmpty ? String(localized: "No output yet.") : tail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if truncated {
                Label("Showing the latest 16 KB", systemImage: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
