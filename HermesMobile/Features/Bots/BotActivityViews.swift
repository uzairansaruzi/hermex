import SwiftUI

/// Settled or live activity in the Sessions log-row style: the reasoning row
/// above the tool rows, both behind the shared "Thinking and Tool Cards" setting.
struct BotActivityBlocksView: View {
    let id: String
    let reasoning: String?
    let toolCalls: [ToolCall]
    var isLive = false

    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsCards = true

    var body: some View {
        if showsCards {
            if let reasoning, !reasoning.isEmpty {
                ReasoningBlockView(text: reasoning, liveStreamID: isLive ? "\(id)-reasoning" : nil)
            }
            if !toolCalls.isEmpty {
                ToolActivityGroupView(group: ToolCallGroup(id: "\(id)-tools", anchorMessageID: nil, toolCalls: toolCalls), isLive: isLive)
            }
        }
    }
}

/// The bot's plan as one log row: `Plan`, then `2 of 5 · current step`.
/// Expanding lists every item with its state; long-press copies the list.
struct BotPlanRowView: View {
    let plan: BotPlan

    @State private var isExpanded = false

    private var detail: String {
        let progress = String(localized: "\(plan.completedCount) of \(plan.items.count)")
        guard let current = plan.current else { return progress }
        return "\(progress) · \(current.content)"
    }

    var body: some View {
        TranscriptLogRowView(
            summary: String(localized: "Plan"),
            detail: detail,
            isExpanded: isExpanded,
            accessibilityLabel: String(localized: "Plan, \(detail)"),
            copyText: { plan.items.map { "\(Self.marker(for: $0)) \($0.content)" }.joined(separator: "\n") },
            toggleExpansion: { isExpanded.toggle() }
        ) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        } status: {
            EmptyView()
        } expandedBody: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.items) { item in
                    Label {
                        Text(item.content)
                            .strikethrough(item.isDone)
                            .foregroundStyle(item.isDone ? .secondary : .primary)
                    } icon: {
                        Image(systemName: Self.symbol(for: item))
                            .foregroundStyle(item.status == "in_progress" ? Color.accentColor : .secondary)
                    }
                    .font(AppFont.caption())
                    .accessibilityLabel(Text("\(Self.stateLabel(for: item)): \(item.content)"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func symbol(for item: BotPlan.Item) -> String {
        switch item.status {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "xmark.circle"
        case "in_progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    private static func marker(for item: BotPlan.Item) -> String {
        switch item.status {
        case "completed": "[x]"
        case "cancelled": "[-]"
        case "in_progress": "[~]"
        default: "[ ]"
        }
    }

    private static func stateLabel(for item: BotPlan.Item) -> String {
        switch item.status {
        case "completed": String(localized: "Done")
        case "cancelled": String(localized: "Cancelled")
        case "in_progress": String(localized: "In progress")
        default: String(localized: "Pending")
        }
    }
}
