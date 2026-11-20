import SwiftUI

struct ChatInlineCommitContext: Equatable {
    let runningPhase: GitCommitPhase?
    let isDisabled: Bool
}

struct GitInlineCommitButton: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let runningPhase: GitCommitPhase?
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
            .foregroundStyle(.appSecondary)
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
