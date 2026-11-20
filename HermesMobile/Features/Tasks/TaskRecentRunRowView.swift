import SwiftUI

struct TaskRecentRunRowView: View {
    let completion: CronRecentCompletion

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let status = statusPresentation
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(completion.displayName)
                    .font(AppFont.subheadline())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if completion.outcome == .stopped {
                    Text(verbatim: status.word)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                }
            }

            Spacer(minLength: 8)

            Text(relativeTime)
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [completion.displayName, status.word, relativeTime].joined(separator: ", ")))
    }

    private var relativeTime: String {
        completion.completedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private var statusPresentation: (word: String, color: Color) {
        switch completion.outcome {
        case .completed: (String(localized: "Completed"), .green)
        case .failed: (String(localized: "Failed"), .red)
        case .stopped: (String(localized: "Stopped"), .secondary)
        case .unknown: (String(localized: "Unknown Status"), .secondary)
        }
    }
}
