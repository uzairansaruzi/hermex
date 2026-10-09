import SwiftUI
import UIKit

/// The agent's plan as one log row: `Plan`, then `2 of 5 · current step`. Expanding lists
/// every item with its state; long-press copies the list. Bot Chat shows it under the turn;
/// a Hermes chat at the top of the plan's turn once it leaves the strip (#1139). It shows
/// whatever the Thinking and Tool Cards setting says.
struct HermesPlanRowView: View {
    let plan: HermesPlan

    @State private var isExpanded = false

    var body: some View {
        TranscriptLogRowView(
            summary: String(localized: "Plan"),
            detail: plan.progress,
            isExpanded: isExpanded,
            accessibilityLabel: String(localized: "Plan, \(plan.progress)"),
            copyText: { plan.copyText },
            toggleExpansion: { isExpanded.toggle() }
        ) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        } status: {
            EmptyView()
        } expandedBody: {
            HermesPlanItemList(plan: plan)
        }
    }
}

/// Every item of a plan with its state, as the row and the strip expand to.
struct HermesPlanItemList: View {
    let plan: HermesPlan

    var body: some View {
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

    private static func symbol(for item: HermesPlan.Item) -> String {
        switch item.status {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "xmark.circle"
        case "in_progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    private static func stateLabel(for item: HermesPlan.Item) -> String {
        switch item.status {
        case "completed": String(localized: "Done")
        case "cancelled": String(localized: "Cancelled")
        case "in_progress": String(localized: "In progress")
        default: String(localized: "Pending")
        }
    }
}

/// A running plan pinned above a Hermes chat's composer (#1139, mock B): one glass line with
/// "2 of 5", the current step and a chevron. Tap expands the list upward, instantly under
/// Reduce Motion; long-press copies it. `onCollapsedHeightChange` reports the line's height,
/// which is all the transcript makes room for: the open list rises over it.
struct HermesPlanStrip: View {
    let plan: HermesPlan
    let onCollapsedHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                ScrollView {
                    HermesPlanItemList(plan: plan)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: TranscriptLogRowMetrics.bodyWindowHeight)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
            line
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onCollapsedHeightChange(height)
                }
        }
        .chatTimelineAccessorySurface(
            fallbackMaterial: .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .frame(maxWidth: 560)
    }

    private var line: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(count)
                .font(.caption.weight(.semibold))
                .fixedSize()
            Text(plan.current?.content ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onLongPressGesture(minimumDuration: 0.45, perform: copy)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "Plan, \([count, plan.current?.content].compactMap { $0 }.joined(separator: ", "))"))
        .accessibilityHint(
            isExpanded
                ? "Double tap to hide details. Long press to copy."
                : "Double tap to show details. Long press to copy."
        )
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text("Copy")) { copy() }
    }

    private var count: String { String(localized: "\(plan.completedCount) of \(plan.items.count)") }

    private func toggle() {
        withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
            isExpanded.toggle()
        }
    }

    private func copy() {
        UIPasteboard.general.string = plan.copyText
        ChatHaptics.copied(isEnabled: isHapticsEnabled)
    }
}
