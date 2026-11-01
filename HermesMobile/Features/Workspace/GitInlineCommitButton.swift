import SwiftUI

/// Presentation inputs for the inline turn-end "Commit & Push" button. When the chat
/// computes a non-nil value, the transcript renders the button under the latest assistant
/// turn; `nil` hides it. Equatable so it can sit on the transcript view cheaply.
struct ChatInlineCommitContext: Equatable {
    let runningPhase: GitCommitPhase?
    let isDisabled: Bool
}

/// Inline "Commit & Push" button shown under the latest assistant turn for git
/// workspaces (issue #315, Slice C, surface B). Tapping it runs the same one-tap commit
/// pipeline as the toolbar menu row — the host owns the work and drives the stacked
/// progress toast; `runningPhase` mirrors that pipeline so the button shows a spinner
/// and the current phase title while it runs.
struct GitInlineCommitButton: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    /// Non-nil while a commit pipeline is running anywhere in the chat.
    let runningPhase: GitCommitPhase?
    /// Disabled while streaming or viewing cached data (writes are unavailable then), or while
    /// the commit sheet writes to a Hermes repository.
    let isDisabled: Bool
    let action: () -> Void

    private var isRunning: Bool { runningPhase != nil }
    private var title: String { runningPhase?.inlineTitle ?? String(localized: "Commit & Push") }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        Button {
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            action()
        } label: {
            HStack(spacing: 6) {
                Group {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 15, weight: .regular))
                    }
                }
                .frame(width: 18, height: 18)

                Text(title)
                    .font(AppFont.mono(style: .subheadline))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: shape)
            .clipShape(shape)
            .chatMinimumHitTarget(in: shape)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isRunning)
        .accessibilityLabel("Commit and push")
    }
}
