import SwiftUI

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

    func showProgress(_ value: GitActionProgress) {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            success = nil
            progress = value
        }
    }

    func showSuccess(_ value: GitActionSuccess, autoDismissAfter duration: Duration = .seconds(6)) {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
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
        withAnimation(.easeInOut(duration: 0.18)) {
            success = nil
        }
    }

    func dismissProgress() {
        withAnimation(.easeInOut(duration: 0.18)) {
            progress = nil
        }
    }
}

struct GitActionToastOverlay: View {
    let state: GitActionToastState

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
                        .foregroundStyle(ZoraBrand.ink, ZoraBrand.success)
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
        .padding(.horizontal, ZoraSpacing.card)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
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
        .padding(ZoraSpacing.card - 2)
        .adaptiveGlass(in: .rect(cornerRadius: ZoraRadius.card - 4))
        .overlay {
            RoundedRectangle(cornerRadius: ZoraRadius.card - 4, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
