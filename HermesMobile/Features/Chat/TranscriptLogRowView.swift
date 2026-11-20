import SwiftUI
import UIKit

enum TranscriptLogRowMetrics {
    static let minimumHeight: CGFloat = 32
    static let bodyIndent: CGFloat = 26
    static let bodyWindowHeight: CGFloat = 240
}

struct TranscriptLogRowBodyWindowLayout: Equatable {
    let frameHeight: CGFloat
    let scrolls: Bool

    static func resolve(contentHeight: CGFloat?, cap: CGFloat) -> Self {
        guard let contentHeight else {
            return Self(frameHeight: 0, scrolls: false)
        }
        return Self(frameHeight: min(contentHeight, cap), scrolls: contentHeight > cap)
    }
}

struct TranscriptLogRowBodyWindow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat?

    var body: some View {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(
            contentHeight: contentHeight,
            cap: TranscriptLogRowMetrics.bodyWindowHeight
        )

        ScrollView(.vertical) {
            content()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    if contentHeight == nil {
                        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                            contentHeight = height
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            contentHeight = height
                        }
                    }
                }
        }
        .scrollDisabled(!layout.scrolls)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: layout.frameHeight)
    }
}

struct TranscriptLogRowView<Icon: View, Accessory: View, Status: View, ExpandedBody: View>: View {
    let summary: String
    let detail: String?
    var isFailure = false
    let isExpanded: Bool
    let accessibilityLabel: String
    let copyText: () -> String
    let toggleExpansion: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let status: () -> Status
    @ViewBuilder let expandedBody: () -> ExpandedBody

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isPressed = false
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowLine

            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    TranscriptLogRowBodyWindow(content: expandedBody)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 1)
                        }
                        .padding(.leading, TranscriptLogRowMetrics.bodyIndent)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: ChatMotion.disclosureTransition(reduceMotion: reduceMotion)
                            )
                        )
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { copiedResetTask?.cancel() }
    }

    private var rowLine: some View {
        HStack(alignment: usesStackedLabel ? .top : .center, spacing: 6) {
            icon()
                .frame(width: 20, height: 18)

            label
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                if showsCopied {
                    Text("Copied")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.trailing, 4)
                }

                if !usesStackedLabel {
                    accessory()
                        .fixedSize()
                        .padding(.trailing, 4)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .frame(width: 16, height: 16)

                status()
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
        .background(
            Color(.appText).opacity(isPressed ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onLongPressGesture(minimumDuration: 0.45, perform: copy) { pressing in
            isPressed = pressing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            isExpanded
                ? "Double tap to hide details. Long press to copy."
                : "Double tap to show details. Long press to copy."
        )
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text("Copy")) { copy() }
    }

    private var usesStackedLabel: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var label: some View {
        if usesStackedLabel {
            VStack(alignment: .leading, spacing: 2) {
                summaryText
                if let detail {
                    detailText(detail).lineLimit(2)
                }
                accessory()
            }
        } else if let detail {
            (summaryText + Text(" ") + detailText(detail))
                .lineLimit(1)
        } else {
            summaryText.lineLimit(1)
        }
    }

    private var summaryText: Text {
        Text(summary)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(isFailure ? Color.red : Color(.appText))
    }

    private func detailText(_ detail: String) -> Text {
        Text(detail)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
    }

    private func toggle() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            toggleExpansion()
        }
    }

    private func copy() {
        isPressed = false
        UIPasteboard.general.string = copyText()
        ChatHaptics.copied(isEnabled: isHapticsEnabled)

        withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
            showsCopied = true
        }

        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                showsCopied = false
            }
        }
    }
}

extension TranscriptLogRowView where Accessory == EmptyView {
    init(
        summary: String,
        detail: String?,
        isFailure: Bool = false,
        isExpanded: Bool,
        accessibilityLabel: String,
        copyText: @escaping () -> String,
        toggleExpansion: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder status: @escaping () -> Status,
        @ViewBuilder expandedBody: @escaping () -> ExpandedBody
    ) {
        self.init(
            summary: summary,
            detail: detail,
            isFailure: isFailure,
            isExpanded: isExpanded,
            accessibilityLabel: accessibilityLabel,
            copyText: copyText,
            toggleExpansion: toggleExpansion,
            icon: icon,
            accessory: { EmptyView() },
            status: status,
            expandedBody: expandedBody
        )
    }
}
