import SwiftUI

struct ForkOrigin: Equatable {
    let parentSessionID: String
    let parent: SessionSummary?

    var title: String {
        guard let parent else { return String(localized: "Forked from another chat") }
        return String(localized: "Forked from \(SessionRowView.displayTitle(for: parent))")
    }

    static func parentSessionID(of session: SessionSummary) -> String? {
        guard session.sessionSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fork",
              let parentID = session.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentID.isEmpty
        else {
            return nil
        }
        return parentID
    }

    static func resolve(session: SessionSummary, parent: SessionSummary?) -> ForkOrigin? {
        guard let parentID = parentSessionID(of: session) else { return nil }
        return ForkOrigin(parentSessionID: parentID, parent: parent)
    }
}

struct ForkOriginRowView: View {
    let origin: ForkOrigin
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.appTertiary)
                    .accessibilityHidden(true)

                Text(origin.title)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.appTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: TranscriptTurnFoldRowView.minimumHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.appSeparator).opacity(0.5))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(origin.title)
        .accessibilityHint(String(localized: "Opens the original chat."))
    }
}
