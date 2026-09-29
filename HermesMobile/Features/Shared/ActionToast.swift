import SwiftUI
import UIKit

/// A short confirmation with one action, such as "Archived · Undo" after a
/// session is archived (#865). `ActionToastState` holds at most one;
/// `ActionToastView` draws it wherever its host places it.
struct ActionToast: Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String
    /// What VoiceOver reads in place of `message`, naming what was acted on
    /// ("Planning, Archived").
    let accessibilityLabel: String
    let actionTitle: String
    let action: @MainActor () -> Void
}

/// Shows one toast at a time. `show` replaces the current toast and restarts
/// its clock; the toast leaves after `displayDuration` unless VoiceOver is
/// running, in which case it stays, with a close control, until the user acts.
/// The owning view keeps this in `@State` and calls `dismiss()` when it goes
/// away, so a toast and its action never outlive their screen.
@MainActor
@Observable
final class ActionToastState {
    static let displayDuration: Duration = .seconds(4)

    private(set) var toast: ActionToast?
    /// False while the current toast waits for the user (VoiceOver was running
    /// when it appeared). The view then shows a close control and moves
    /// VoiceOver focus to the toast.
    private(set) var dismissesAutomatically = true

    private var dismissTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let isVoiceOverRunning: @MainActor () -> Bool

    /// Tests inject `sleep` to end the display time on cue, and
    /// `isVoiceOverRunning` to stand in for the system setting.
    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        isVoiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }
    ) {
        self.sleep = sleep
        self.isVoiceOverRunning = isVoiceOverRunning
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.25)
    }

    func show(_ newToast: ActionToast) {
        dismissTask?.cancel()
        dismissTask = nil

        let waitsForUser = isVoiceOverRunning()
        toast = newToast
        dismissesAutomatically = !waitsForUser
        guard !waitsForUser else { return }

        let toastID = newToast.id
        dismissTask = Task { [weak self, sleep] in
            do {
                try await sleep(Self.displayDuration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.toast?.id == toastID else { return }
            self.dismiss()
        }
    }

    /// Runs the toast's action once and removes the toast. A second tap on a
    /// toast that already acted, or was replaced, does nothing.
    func performAction(of actedOn: ActionToast) {
        guard toast?.id == actedOn.id else { return }
        dismiss()
        actedOn.action()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
        dismissesAutomatically = true
    }
}

/// Draws `state`'s toast as a glass capsule that fills its host's width. At
/// accessibility text sizes the action drops below the message and the capsule
/// becomes a rounded card. Reduce Motion swaps the slide for a fade.
struct ActionToastView: View {
    let state: ActionToastState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var messageIsFocused: Bool

    var body: some View {
        ZStack {
            if let toast = state.toast {
                toastBody(toast)
                    .id(toast.id)
                    .transition(ActionToastState.transition(reduceMotion: reduceMotion))
                    .task(id: toast.id) {
                        // VoiceOver users get the toast in focus, so Undo is
                        // one swipe away and nothing times out under them.
                        if !state.dismissesAutomatically {
                            messageIsFocused = true
                        }
                    }
            }
        }
        .animation(ActionToastState.animation(reduceMotion: reduceMotion), value: state.toast?.id)
    }

    @ViewBuilder
    private func toastBody(_ toast: ActionToast) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                message(toast)
                HStack(spacing: 4) {
                    actionButton(toast, horizontalPadding: 0)
                    Spacer(minLength: 0)
                    if !state.dismissesAutomatically {
                        closeButton
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 6, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(fallbackMaterial: .regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 4) {
                message(toast)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButton(toast, horizontalPadding: 10)
                if !state.dismissesAutomatically {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 1, height: 20)
                        .accessibilityHidden(true)
                    closeButton
                }
            }
            .padding(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 6))
            .frame(minHeight: 50)
            .adaptiveGlass(fallbackMaterial: .regularMaterial, in: Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    private func message(_ toast: ActionToast) -> some View {
        HStack(spacing: 9) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.secondary)
            Text(toast.message)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
        .font(AppFont.subheadline(weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.accessibilityLabel)
        .accessibilityFocused($messageIsFocused)
    }

    private func actionButton(_ toast: ActionToast, horizontalPadding: CGFloat) -> some View {
        Button {
            state.performAction(of: toast)
        } label: {
            Text(toast.actionTitle)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            state.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
