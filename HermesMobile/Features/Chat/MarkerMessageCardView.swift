import SwiftUI

/// Collapsible card for context-compaction marker messages, replacing the user
/// bubble they would otherwise render as. Mirrors the web UI's collapsed cards
/// and follows the `ReasoningBlockView` disclosure pattern.
struct MarkerMessageCardView: View {
    let kind: ChatMarkerMessageKind
    let content: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @State private var isExpanded = false

    var body: some View {
        let cardBody = ChatMarkerMessageClassifier.cardBody(for: kind, content: content)
        let summary = summary(for: cardBody)

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                chatDisclosureToggled()
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                header(summary: summary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.title), \(summary)")
            .accessibilityHint(isExpanded ? String(localized: "Double tap to collapse details.") : String(localized: "Double tap to expand details."))

            if isExpanded {
                Text(cardBody.isEmpty ? kind.title : cardBody)
                    .font(AppFont.caption())
                    .foregroundStyle(.appPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .thinMaterial,
            cornerRadius: 10
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var iconName: String {
        switch kind {
        case .contextCompaction:
            return "arrow.down.right.and.arrow.up.left"
        case .preservedTaskList:
            return "checklist"
        case .compressionReference:
            return "star"
        }
    }

    private func header(summary: String) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.appSecondary)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    summaryText(summary, lineLimit: 2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryText(summary, lineLimit: 1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.appSecondary)
        }
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(kind.title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.appPrimary)
            .lineLimit(1)
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text(value)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(lineLimit)
    }

    private func summary(for value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The synthesized anchor card mirrors the web UI's
        // "Reference only · <preview>" collapsed line.
        if kind == .compressionReference {
            guard !oneLine.isEmpty else { return String(localized: "Reference only") }
            return String(localized: "Reference only · \(truncated(oneLine))")
        }

        if oneLine.isEmpty {
            return kind.title
        }

        return truncated(oneLine)
    }

    private func truncated(_ oneLine: String) -> String {
        if oneLine.count <= 80 {
            return oneLine
        }

        return "\(oneLine.prefix(80))..."
    }
}

/// A scheduled task's run prompt (#1413) in place of its user bubble, styled like the
/// delegation completion card: the host wrote the row, not the user. Collapsed, it names the
/// job's skills and previews its text; expanded, it shows that text and Copy, which copies the
/// whole row, hint included (`onCopy`, the bubble's Copy). The run's time stays in the meta row.
struct CronRunPromptCard: View {
    let prompt: CronRunPrompt
    let onCopy: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                chatDisclosureToggled()
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityHint(isExpanded ? String(localized: "Double tap to collapse details.") : String(localized: "Double tap to expand details."))

            if isExpanded {
                VStack(alignment: .trailing, spacing: 8) {
                    if !prompt.body.isEmpty {
                        Text(prompt.body)
                            .font(.body)
                            .foregroundStyle(.appPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let onCopy {
                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .chatMinimumHitTarget(in: Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy task prompt")
                    }
                }
                .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(12)
        .background(.appMaterial(.thinMaterial), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(.quaternary, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 7))
                titleLayout {
                    Text("Scheduled task")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.appPrimary)
                    if !prompt.skills.isEmpty {
                        Text(prompt.skills.joined(separator: " "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.appSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if !isExpanded, let preview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.appSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.appTertiary)
                .padding(.top, 6)
        }
        .contentShape(Rectangle())
    }

    /// The body's first line, which opens the collapsed card.
    private var preview: String? {
        prompt.body.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private var accessibilityLabel: String {
        ([String(localized: "Scheduled task")] + prompt.skills + (isExpanded ? [] : [preview].compactMap { $0 }))
            .joined(separator: ", ")
    }
}
