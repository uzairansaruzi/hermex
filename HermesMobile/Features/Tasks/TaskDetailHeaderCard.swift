import SwiftUI

struct TaskDetailHeaderCard: View {
    let job: CronJob
    let runningElapsed: Double?
    let isBusy: Bool
    let canSeeFullOutput: Bool
    var showsRunNow = true
    var runNowState: TaskDetailViewModel.RunNowState = .idle
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

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(AppFont.title3().bold())
                    .lineLimit(3)

                Text(scheduleSentence)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            StatusBadge(text: statusText, color: statusColor)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var nextRunBlock: some View {
        if let running = runningElapsed {
            VStack(alignment: .leading, spacing: 1) {
                Text(CronJobRowView.elapsedText(running))
                    .font(AppFont.title2(weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Running now")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if let next = job.nextRunAt?.date {
            VStack(alignment: .leading, spacing: 1) {
                Text(CronScheduleHumanizer.countdown(to: next))
                    .font(AppFont.title2(weight: .semibold))
                Text("Next run · \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if let last = job.lastRunAt?.date {
            VStack(alignment: .leading, spacing: 1) {
                Text("Not scheduled")
                    .font(AppFont.title3(weight: .semibold))
                    .foregroundStyle(.appSecondary)
                Text("Last run · \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func failureBlock(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(failure)
                    .font(AppFont.footnote())
                    .foregroundStyle(.appPrimary)
                    .lineLimit(3)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Last run failed. \(failure)"))

            if canSeeFullOutput {
                Button("See full output", action: seeFullOutput)
                    .font(AppFont.footnote(weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var actionFooter: some View {
        let runButton = footerButton(
            title: String(localized: "Run now"),
            systemImage: "play.fill",
            isWaiting: runNowState == .requested,
            action: runNow
        )
        .disabled(runNowState != .idle)
        let pauseButton = footerButton(
            title: job.pauseResumeTitle,
            systemImage: job.pauseResumeSystemImage,
            action: togglePauseResume
        )

        Group {
            if !showsRunNow {
                pauseButton
            } else if dynamicTypeSize.isAccessibilitySize {
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
        isWaiting: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isWaiting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.appSecondary)
                }
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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
}
