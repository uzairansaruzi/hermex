import SwiftUI
import UIKit

/// A Hermes session's `/btw` card, docked above the composer in the clarification's slot
/// (#1013, design pick B). It shows the question, then a static waiting line, then the
/// answer, or that the answer is unavailable. Past the clarification card's body cap, its
/// body scrolls; Expand opens it full screen, and Close ends it. Its measured height is the
/// slot's footprint, so the live tail streams above it.
struct HermesBtwCard: View {
    let btw: HermesBtw
    /// Height between the chat's top safe edge and the slot's bottom edge.
    let maximumExpandedHeight: CGFloat
    let onExpand: () -> Void
    let onClose: () -> Void

    @State private var bodyHeight: CGFloat?
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HermesBtwHeader(onExpand: onExpand, onClose: onClose)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(btw.question)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pendingRequestBlockSurface()
                    HermesBtwAnswer(state: btw.state, isFullScreen: false)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(bodyHeight ?? 0, maximumBodyHeight))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .pendingRequestCardSurface(cornerRadius: ChatComposerMetrics.cardCornerRadius)
        .opacity(bodyHeight == nil ? 0 : 1)
        .accessibilityElement(children: .contain)
        .modifier(HermesBtwAnnouncement(state: btw.state))
    }

    /// The clarification card's body cap, and never so tall that no transcript shows above
    /// the card: it takes layout space, unlike the clarification card, which overlays.
    private var maximumBodyHeight: CGFloat {
        max(44, min(ClarificationRequestHeightPolicy.bodyHeightCap, maximumExpandedHeight - headerHeight - 28 - 44))
    }
}

/// The `/btw` card collapsed to one line while a host request takes the slot (#1013): the
/// request card covers it when expanded. Expand opens the answer full screen.
struct HermesBtwBar: View {
    let btw: HermesBtw
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExpand) {
                HStack(spacing: 8) {
                    HermesBtwLabel()
                    Text(btw.question)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand side question")
            .accessibilityValue(btw.question)

            HermesBtwCloseButton(action: onClose)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 560)
        .pendingRequestCardSurface(cornerRadius: ChatComposerMetrics.cardCornerRadius)
        .accessibilityElement(children: .contain)
        .modifier(HermesBtwAnnouncement(state: btw.state))
    }
}

/// The `/btw` answer full screen (#1013, expand pick 1): Collapse returns to the card, Close
/// ends the question. The chat is hidden, so a running turn shows as a static pill, which
/// says when the turn waits on the user. On iPad the answer keeps a readable column.
struct HermesBtwFullScreen: View {
    let btw: HermesBtw
    let sessionTitle: String
    /// The hidden chat's run, as its own run-status pill names it; nil when idle.
    let runStatus: ChatActiveRunStatusKind?
    let onCollapse: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(btw.question)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HermesBtwAnswer(state: btw.state, isFullScreen: true)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                if let runStatus {
                    HermesBtwRunPill(status: runStatus)
                        .padding(.bottom, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        // The command's name, as the card's label reads it.
                        Text(verbatim: "BTW")
                            .font(.headline)
                            .accessibilityLabel("Side question")
                        Text(sessionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCollapse) {
                        Label("Collapse side question", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Label("Close side question", systemImage: "xmark")
                    }
                }
            }
        }
    }
}

/// The card's header: what it is, Expand, and Close.
private struct HermesBtwHeader: View {
    let onExpand: () -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            HermesBtwLabel()
            Spacer(minLength: 8)
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.primary.opacity(0.08), in: Circle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel("Expand side question")
            HermesBtwCloseButton(action: onClose)
        }
    }
}

/// The command's name, which stays as typed in every language.
private struct HermesBtwLabel: View {
    var body: some View {
        Label { Text(verbatim: "BTW") } icon: { Image(systemName: "text.bubble") }
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Side question")
    }
}

private struct HermesBtwCloseButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: buttonSize, height: buttonSize)
                .background(.primary.opacity(0.08), in: Circle())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel("Close side question")
    }
}

/// The answer as the card and the full screen show it: a static waiting line (nothing
/// repaints), the answer, or why it is unavailable.
private struct HermesBtwAnswer: View {
    let state: HermesBtw.State
    let isFullScreen: Bool

    var body: some View {
        switch state {
        case .waiting:
            HStack(spacing: 8) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("Answering from a snapshot of this chat")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        case .answered(let text):
            VStack(alignment: .leading, spacing: 8) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No answer produced.")
                        .font(isFullScreen ? .body : .subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    MarkdownRenderer(content: text)
                }
                Text("From a snapshot · no tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Answer unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text("The stream reconnected without this answer. Ask again with /btw.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The run going on behind the full-screen answer. Static: no timer, nothing repaints.
private struct HermesBtwRunPill: View {
    let status: ChatActiveRunStatusKind

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
    }
}

/// Tells VoiceOver when the answer arrives or is lost; waiting stays silent.
private struct HermesBtwAnnouncement: ViewModifier {
    let state: HermesBtw.State

    func body(content: Content) -> some View {
        content.onChange(of: state) { _, state in
            guard UIAccessibility.isVoiceOverRunning else { return }
            switch state {
            case .answered: AccessibilityNotification.Announcement(String(localized: "Side answer ready")).post()
            case .unavailable: AccessibilityNotification.Announcement(String(localized: "Answer unavailable")).post()
            case .waiting: break
            }
        }
    }
}
