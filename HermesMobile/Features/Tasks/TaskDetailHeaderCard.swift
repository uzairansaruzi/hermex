import SwiftUI

/// Task Detail's first card: what this task is, when it runs next, and the two
/// controls an operator reaches for. When the last run failed the card takes an
/// error tint and carries the reason, because that is the only thing on the
/// screen worth reading first.
struct TaskDetailHeaderCard: View {
    let job: CronJob
    let runningElapsed: Double?
    let isBusy: Bool
    let canSeeFullOutput: Bool
    let runNow: () -> Void
    let togglePauseResume: () -> Void
    let seeFullOutput: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                titleRow
                nextRunBlock

                if let failure = job.failureSummary {
                    failureBlock(failure)
                }
            }
        } footer: {
            actionFooter
        }
    }

    // MARK: - Pieces

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.title3.bold())
                    .lineLimit(3)

                Text(scheduleSentence)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            StatusBadge(text: statusText, color: statusColor)
        }
        .accessibilityElement(children: .combine)
    }

    /// The countdown reads big; the absolute time sits under it for the reader
    /// who wants the actual clock. Both are computed on render rather than
    /// ticked by a timer — a label that repaints every second costs more than
    /// the freshness is worth, and Refresh brings it up to date.
    @ViewBuilder
    private var nextRunBlock: some View {
        if let running = runningElapsed {
            VStack(alignment: .leading, spacing: 1) {
                Text(CronJobRowView.elapsedText(running))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("Running now")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let next = job.nextRunAt?.date {
            VStack(alignment: .leading, spacing: 1) {
                Text(CronScheduleHumanizer.countdown(to: next))
                    .font(.title2.weight(.semibold))
                Text("Next run · \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let last = job.lastRunAt?.date {
            VStack(alignment: .leading, spacing: 1) {
                Text("Not scheduled")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Last run · \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func failureBlock(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Last run failed. \(failure)"))

            if canSeeFullOutput {
                Button("See full output", action: seeFullOutput)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The card's two controls, as its bottom edge rather than as objects
    /// sitting on it.
    ///
    /// Neither action is the primary one — you press whichever matches what you
    /// want — so they carry equal weight, and no fill competes with the error
    /// box above them for the one colour on this card that means something.
    @ViewBuilder
    private var actionFooter: some View {
        let runButton = footerButton(
            title: String(localized: "Run now"),
            systemImage: "play.fill",
            action: runNow
        )
        let pauseButton = footerButton(
            title: pauseResumeTitle,
            systemImage: pauseResumeSystemImage,
            action: togglePauseResume
        )

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Two labels will not sit side by side at these sizes, so the
                // divider turns with them.
                VStack(spacing: 0) {
                    runButton
                    Divider()
                    pauseButton
                }
            } else {
                HStack(spacing: 0) {
                    runButton
                    Divider()
                    pauseButton
                }
            }
        }
        .disabled(isBusy)
    }

    private func footerButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        // Plain keeps the label as the whole control, so the row reads as part
        // of the card; the style's press dimming is the tap confirmation.
        .buttonStyle(.plain)
    }

    // MARK: - Presentation

    /// The humanised schedule, or the server's own string when the expression
    /// is not one we recognise — never a guess.
    private var scheduleSentence: String {
        job.scheduleDescription?.sentence ?? job.scheduleText ?? String(localized: "Not available")
    }

    private var statusText: String {
        runningElapsed == nil ? job.status.label : String(localized: "Running")
    }

    private var statusColor: Color {
        guard runningElapsed == nil else { return .blue }

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

    private var shouldResume: Bool {
        job.status == .paused || job.status == .off
    }

    private var pauseResumeTitle: String {
        shouldResume ? String(localized: "Resume") : String(localized: "Pause")
    }

    /// Resume is a circled triangle, never `play.fill`: beside "Run now" the
    /// same solid triangle twice would say the two buttons do the same thing.
    private var pauseResumeSystemImage: String {
        shouldResume ? "play.circle" : "pause.fill"
    }
}
