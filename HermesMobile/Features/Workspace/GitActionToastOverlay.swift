import SwiftUI
import UIKit

struct GitActionProgress: Equatable {
    let title: String
    var subtitle: String?
    var detailLines: [String] = []
}

struct GitActionSuccess: Equatable, Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String?
    var detailLines: [String] = []
}

@MainActor
@Observable
final class GitActionToastState {
    private(set) var progress: GitActionProgress?
    private(set) var success: GitActionSuccess?
    private var dismissTask: Task<Void, Never>?

    static func toastAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    func showProgress(_ value: GitActionProgress) {
        dismissTask?.cancel()
        animate {
            success = nil
            progress = value
        }
    }

    func showSuccess(_ value: GitActionSuccess, autoDismissAfter duration: Duration = .seconds(6)) {
        dismissTask?.cancel()
        animate {
            progress = nil
            success = value
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissSuccess()
        }
    }

    func dismissSuccess() {
        dismissTask?.cancel()
        dismissTask = nil
        animate {
            success = nil
        }
    }

    func dismissProgress() {
        animate {
            progress = nil
        }
    }

    private func animate(_ updates: () -> Void) {
        withAnimation(Self.toastAnimation(reduceMotion: UIAccessibility.isReduceMotionEnabled), updates)
    }
}

struct GitActionToastOverlay: View {
    let state: GitActionToastState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let success = state.success {
                toast(
                    title: success.title,
                    subtitle: success.subtitle,
                    detailLines: success.detailLines,
                    isDismissable: true
                ) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white, .green)
                        .symbolRenderingMode(.palette)
                }
                .id(success.id)
            } else if let progress = state.progress {
                toast(
                    title: progress.title,
                    subtitle: progress.subtitle,
                    detailLines: progress.detailLines,
                    isDismissable: false
                ) {
                    ProgressView().controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(GitActionToastState.toastTransition(reduceMotion: reduceMotion))
    }

    private func toast<Icon: View>(
        title: String,
        subtitle: String?,
        detailLines: [String],
        isDismissable: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon().frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFont.subheadline(weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(AppFont.caption()).foregroundStyle(.secondary)
                }
                ForEach(detailLines, id: \.self) { line in
                    Text(line).font(AppFont.caption()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDismissable {
                Button(action: state.dismissSuccess) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .adaptiveGlass(in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
