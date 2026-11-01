import SwiftUI

/// Where a forked chat came from, for the "Forked from" row at the top of its
/// transcript. Only chats made by Fork From Here or `/branch` count: upstream
/// stamps those `session_source: "fork"` with a `parent_session_id`. Agent
/// child sessions (subagents, cron, CLI `/new`) share `parent_session_id`
/// but are not forks, so they get no row. A Hermes branch is marked in its own
/// row instead, and its chat reads it from the host (`HermesBranchParent`, #1051).
struct ForkOrigin: Equatable {
    let parentSessionID: String
    /// The parent as the session list cached it; nil means a tap fetches it.
    let parent: SessionSummary?

    /// The row's label: the parent's list title, or a fallback when the parent
    /// is not cached.
    var title: String {
        guard let parent else { return String(localized: "Forked from another chat") }
        return String(localized: "Forked from \(SessionRowView.displayTitle(for: parent))")
    }

    /// The parent to look up, or nil when `session` is not a fork. Matches the
    /// webui's own test: `session_source`, trimmed and lowercased, is "fork".
    static func parentSessionID(of session: SessionSummary) -> String? {
        guard session.sessionSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fork",
              let parentID = session.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentID.isEmpty
        else {
            return nil
        }
        return parentID
    }

    /// - Parameter parent: the cached parent session, if the list held it.
    static func resolve(session: SessionSummary, parent: SessionSummary?) -> ForkOrigin? {
        guard let parentID = parentSessionID(of: session) else { return nil }
        return ForkOrigin(parentSessionID: parentID, parent: parent)
    }
}

/// The first transcript row of a forked chat. Styled like the turn-fold row:
/// a 44 pt secondary line with a bottom hairline. Tapping opens the parent.
struct ForkOriginRowView: View {
    let origin: ForkOrigin
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(origin.title)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: TranscriptTurnFoldRowView.minimumHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.separator).opacity(0.5))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(origin.title)
        .accessibilityHint(String(localized: "Opens the original chat."))
    }
}
