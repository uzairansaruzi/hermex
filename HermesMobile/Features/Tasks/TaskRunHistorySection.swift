import SwiftUI

struct TaskRunHistorySection: View {
    let runs: [CronRunHistoryItem]
    let total: Int?
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let remainingCount: Int
    let errorMessage: String?
    let outcome: (CronRunHistoryItem) -> TaskDetailViewModel.RunOutcome?
    let selectRun: (CronRunHistoryItem) -> Void
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        SectionCard(title: sectionTitle) {
            VStack(alignment: .leading, spacing: 0) {
                if let errorMessage {
                    inlineError(errorMessage)
                }

                if runs.isEmpty {
                    emptyState
                } else {
                    ForEach(runs, id: \.id) { run in
                        Button {
                            selectRun(run)
                        } label: {
                            TaskRunHistoryRow(run: run, outcome: outcome(run))
                        }
                        .buttonStyle(.plain)
                    }

                    if canLoadMore {
                        loadMoreRow
                    }
                }
            }
        }
    }

    private var sectionTitle: String {
        guard let total else { return String(localized: "Run History") }
        return String(localized: "Run History · \(total)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading runs...")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else if errorMessage == nil {
            Text("This task has not produced any output yet.")
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
                .padding(.vertical, 4)
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
            Button("Try Again", action: retry)
                .font(AppFont.footnote(weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, runs.isEmpty ? 0 : 10)
    }

    private var loadMoreRow: some View {
        Button(action: loadMore) {
            HStack(spacing: 8) {
                if isLoadingMore {
                    ProgressView()
                }
                Text(remainingCount > 0 ? String(localized: "Load \(remainingCount) more") : String(localized: "Load more"))
                    .font(AppFont.footnote(weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(isLoadingMore)
    }
}

struct TaskRunHistoryRow: View {
    let run: CronRunHistoryItem
    let outcome: TaskDetailViewModel.RunOutcome?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appPrimary)
                    .lineLimit(2)

                if let detail = detailText {
                    Text(detail)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([titleText] + statusParts + metaParts).joined(separator: ", ")))
        .accessibilityHint(Text("Opens this run's full output"))
        .accessibilityAddTraits(.isButton)
    }

    private var titleText: String {
        guard let date = run.date else { return run.filename }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var detailText: String? {
        let parts = (outcome == .completed ? [] : statusParts) + metaParts
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var metaParts: [String] {
        var parts: [String] = []

        if let size = run.size, size >= 0 {
            parts.append(size.formatted(.byteCount(style: .file)))
        }

        if let duration = run.usage.durationSeconds, duration.isFinite, duration > 0 {
            parts.append(
                Duration.seconds(duration)
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
            )
        }

        if let model = run.usage.model, !model.isEmpty {
            parts.append(model)
        }

        if let tokens = run.usage.totalTokens, tokens > 0 {
            parts.append(String(localized: "\(usageFormattedTokens(tokens)) tokens"))
        }

        if let cost = run.usage.estimatedCostUsd, cost.isFinite, cost > 0 {
            parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(0...4))))
        }

        return parts
    }

    private var statusParts: [String] {
        switch outcome {
        case .running: return [String(localized: "Running")]
        case .completed: return [String(localized: "Completed")]
        case .failed(let reason): return [String(localized: "Failed")] + [reason].compactMap { $0 }
        case nil: return []
        }
    }

    private var dotColor: Color {
        switch outcome {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case nil: return Color(uiColor: .appTextTertiary)
        }
    }
}
