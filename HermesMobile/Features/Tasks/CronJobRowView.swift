import SwiftUI

struct CronJobRowView: View {
    let job: CronJob
    let group: TaskAgendaGroup
    let runningElapsed: Double?
    var profile: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule(style: .continuous)
                .fill(tint)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let profile, !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        name
                        Spacer(minLength: 0)
                        profileLabel(profile)
                    }
                } else {
                    name
                    if let profile { profileLabel(profile) }
                }

                Text(metaText)
                    .font(AppFont.caption())
                    .foregroundStyle(metaStyle)
                    .lineLimit(metaLineLimit)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityParts.joined(separator: ", ")))
    }

    private var name: some View {
        Text(job.displayName)
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(isDimmed ? AnyShapeStyle(.appSecondary) : AnyShapeStyle(.appPrimary))
            .lineLimit(nameLineLimit)
    }

    private func profileLabel(_ profile: String) -> some View {
        Text(verbatim: profile)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private var accessibilityParts: [String] {
        let parts = [job.displayName, statusWord, metaText]
        guard let profile else { return parts }
        return parts + [String(localized: "Profile"), profile]
    }

    private var metaText: String {
        switch group {
        case .now:
            guard let runningElapsed else { return String(localized: "Running") }
            return "\(String(localized: "Running")) · \(Self.elapsedText(runningElapsed))"
        case .needsAttention:
            let headline = String(localized: "Last run failed")
            guard let reason = job.failureSummary else { return headline }
            return "\(headline) · \(reason)"
        case .paused:
            return scheduleSentence
        case .laterToday, .tomorrow, .thisWeek, .later:
            guard let next = job.nextRunAt?.date else { return scheduleSentence }
            return "\(nextRunText(next)) · \(scheduleRecurrence)"
        }
    }

    private var scheduleSentence: String {
        job.scheduleDescription?.sentence ?? job.scheduleText ?? String(localized: "Not available")
    }

    private var scheduleRecurrence: String {
        job.scheduleDescription?.recurrence ?? job.scheduleText ?? String(localized: "Not available")
    }

    private func nextRunText(_ date: Date) -> String {
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    static func elapsedText(_ elapsed: Double) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed.rounded()))s"
        }

        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    private var tint: Color {
        switch group {
        case .now:
            return .blue
        case .needsAttention:
            return .red
        case .paused:
            return .secondary
        case .laterToday, .tomorrow, .thisWeek, .later:
            return .green
        }
    }

    private var isDimmed: Bool { group == .paused }

    private var metaStyle: AnyShapeStyle {
        switch group {
        case .needsAttention:
            return AnyShapeStyle(.red)
        case .paused:
            return AnyShapeStyle(.appTertiary)
        default:
            return AnyShapeStyle(.appSecondary)
        }
    }

    private var nameLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var metaLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 1
    }

    private var statusWord: String {
        switch group {
        case .now:
            return String(localized: "Running")
        case .needsAttention:
            return String(localized: "Needs Attention")
        case .paused:
            return String(localized: "Paused")
        case .laterToday, .tomorrow, .thisWeek, .later:
            return String(localized: "Active")
        }
    }
}
