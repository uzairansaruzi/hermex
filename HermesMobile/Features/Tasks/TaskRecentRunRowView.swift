import SwiftUI

/// One row of the Tasks list's "Ran Recently" group: an ok/failed dot, the
/// job's name, and how long ago it finished. The list decides whether the row
/// links to Task Detail; this view only draws it.
struct TaskRecentRunRowView: View {
    let completion: CronRecentCompletion

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(completion.didFail ? Color.red : Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(completion.displayName)
                .font(.subheadline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)

            Spacer(minLength: 8)

            Text(relativeTime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [completion.displayName, statusWord, relativeTime].joined(separator: ", ")))
    }

    /// Re-evaluated whenever the row is redrawn, which a refresh forces by
    /// replacing the feed.
    private var relativeTime: String {
        completion.completedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private var statusWord: String {
        completion.didFail ? String(localized: "Failed") : String(localized: "Completed")
    }
}
