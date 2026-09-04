import SwiftUI

/// Task Detail's run history: every past run the server still holds, newest
/// first, a page at a time.
///
/// Rows carry only what the server actually reports for every run — when it
/// finished and how big it was. Model, duration and cost come from `usage`,
/// which is empty for most runs, so they are appended when present and take no
/// space when not.
struct TaskRunHistorySection: View {
    let runs: [CronRunHistoryItem]
    let total: Int?
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let remainingCount: Int
    let errorMessage: String?
    /// Reports the one run the job record can vouch for. See
    /// `TaskDetailViewModel.isFailedRun(_:)`.
    let isFailedRun: (CronRunHistoryItem) -> Bool
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
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 {
                            Divider()
                        }

                        Button {
                            selectRun(run)
                        } label: {
                            TaskRunHistoryRow(run: run, hasFailed: isFailedRun(run))
                        }
                        .buttonStyle(.plain)
                    }

                    if canLoadMore {
                        Divider()
                        loadMoreRow
                    }
                }
            }
        }
    }

    // MARK: - Pieces

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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else if errorMessage == nil {
            Text("This task has not produced any output yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }

    /// History failing is a section-local problem: it never takes the screen
    /// down with it, so the retry lives here rather than in a full-page state.
    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
                .font(.footnote.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
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

/// One past run. Date and size are always there; everything after them is a
/// decoration the server may or may not have parsed.
struct TaskRunHistoryRow: View {
    let run: CronRunHistoryItem
    let hasFailed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(hasFailed ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([titleText, statusWord] + metaParts).joined(separator: ", ")))
        .accessibilityHint(Text("Opens this run's full output"))
        .accessibilityAddTraits(.isButton)
    }

    private var titleText: String {
        guard let modified = run.modified else { return run.filename }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }

    /// The status word plus `metaParts`, joined rather than laid out in columns
    /// so a run with empty `usage` leaves no gap where its decorations would be.
    private var detailText: String? {
        let parts = hasFailed ? [statusWord] + metaParts : metaParts
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Size first, because the server reports it for every run, then whatever
    /// `usage` happened to carry.
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

        if let cost = run.usage.estimatedCostUsd, cost.isFinite, cost > 0 {
            parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(0...4))))
        }

        return parts
    }

    private var statusWord: String {
        hasFailed ? String(localized: "Failed") : String(localized: "Completed")
    }
}
