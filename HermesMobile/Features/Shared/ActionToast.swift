import SwiftUI
import UIKit

/// A short confirmation with one action, such as "Archived · Undo" after a
/// session is archived (#865), a notice with none, such as why a session link
/// opened nothing (#1176), or a Git action's progress and then its result
/// (#1410). `ActionToastState` holds at most one; `ActionToastView` draws it
/// wherever its host places it.
struct ActionToast: Identifiable {
    /// What the toast reports. Tone tints only the glyph and is what VoiceOver
    /// reads as the toast's value; the glass stays neutral.
    enum Tone {
        case neutral
        /// Work still running: the operation's glyph stays gray and nothing
        /// times out until `ActionToastState.update` reports the result.
        case busy
        case success
        case failure
    }

    /// Kept by `ActionToastState.update`, so a busy toast that becomes its
    /// result stays the same toast (and keeps VoiceOver's focus).
    var id = UUID()
    let message: String
    let systemImage: String
    /// What VoiceOver reads in place of `message`, naming what was acted on
    /// ("Planning, Archived").
    let accessibilityLabel: String
    var tone: Tone = .neutral
    /// The edge of its host the toast shows at. A host with one placement
    /// leaves the default; chat puts Git feedback at the top (#1410).
    var edge: Edge = .bottom
    /// Secondary lines under the message, such as a Git action's branch and
    /// commit. A result with detail stays longer.
    var detailLines: [String] = []
    /// Nil, with `action`, for a notice.
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil

    /// A non-blocking failure, shown in place of an alert (#1410).
    static func failure(_ message: String) -> ActionToast {
        ActionToast(message: message, systemImage: "exclamationmark.triangle.fill",
                    accessibilityLabel: message, tone: .failure)
    }
}

/// Shows one toast at a time. `show` replaces the current toast, restarts its
/// clock and returns its ID; `update` and `dismiss(_:)` act only on that ID,
/// so an operation that finishes late can't overwrite a newer toast or revive
/// one the user swiped away. A toast leaves after `displayDuration`
/// (`detailedDisplayDuration` with detail lines) unless it is busy or VoiceOver
/// is running, in which case it stays, with a close control, until the user acts.
/// The owning view keeps this in `@State` and calls `dismiss()` when it goes
/// away, so a toast and its action never outlive their screen.
@MainActor
@Observable
final class ActionToastState {
    static let displayDuration: Duration = .seconds(4)
    static let detailedDisplayDuration: Duration = .seconds(6)

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

    /// The toast enters from, and leaves toward, the edge its host pins it to.
    static func transition(reduceMotion: Bool, edge: Edge = .bottom) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.25)
    }

    @discardableResult
    func show(_ newToast: ActionToast) -> ActionToast.ID {
        present(newToast)
        return newToast.id
    }

    /// Replaces the content of the toast `id` names, keeping its identity, and
    /// restarts the clock for the new content. Does nothing once that toast has
    /// left or been replaced.
    func update(_ id: ActionToast.ID, to content: ActionToast) {
        guard toast?.id == id else { return }
        var updated = content
        updated.id = id
        present(updated)
    }

    /// The current toast when it shows at `edge`, so a host that places
    /// toasts at two edges still shows only one at a time.
    func toast(at edge: Edge) -> ActionToast? {
        toast?.edge == edge ? toast : nil
    }

    /// Runs the toast's action once and removes the toast. A second tap on a
    /// toast that already acted, or was replaced, does nothing.
    func performAction(of actedOn: ActionToast) {
        guard toast?.id == actedOn.id else { return }
        dismiss()
        actedOn.action?()
    }

    /// Removes the toast `id` names, and nothing newer.
    func dismiss(_ id: ActionToast.ID) {
        guard toast?.id == id else { return }
        dismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
        dismissesAutomatically = true
    }

    private func present(_ newToast: ActionToast) {
        dismissTask?.cancel()
        dismissTask = nil

        let waitsForUser = isVoiceOverRunning()
        toast = newToast
        dismissesAutomatically = !waitsForUser
        guard !waitsForUser, newToast.tone != .busy else { return }

        let toastID = newToast.id
        let duration = newToast.detailLines.isEmpty ? Self.displayDuration : Self.detailedDisplayDuration
        dismissTask = Task { [weak self, sleep] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.toast?.id == toastID else { return }
            self.dismiss()
        }
    }
}

/// When a sideways drag dismisses a toast (#1410): past a quarter of its width,
/// or on a flick the same way. A mostly vertical drag never does.
enum ActionToastDismissPolicy {
    static let flickVelocity: CGFloat = 600

    static func shouldDismiss(translation: CGSize, velocity: CGSize, width: CGFloat) -> Bool {
        guard abs(translation.width) > abs(translation.height) else { return false }
        if abs(translation.width) >= width / 4 { return true }
        return abs(velocity.width) >= flickVelocity && (velocity.width > 0) == (translation.width > 0)
    }
}

/// Draws `state`'s toast as a glass capsule that fills its host's width, or a
/// rounded card when it has detail lines, is a failure, or uses an
/// accessibility text size (the action then drops below the message). `edge`
/// is the edge the host pins it to; it draws only a toast that shows there. A
/// sideways swipe dismisses it; Reduce Motion swaps every slide for a fade.
struct ActionToastView: View {
    let state: ActionToastState
    var edge: Edge = .bottom

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var messageIsFocused: Bool

    var body: some View {
        ZStack {
            if let toast = state.toast(at: edge) {
                toastBody(toast)
                    .modifier(ActionToastSwipe { state.dismiss(toast.id) })
                    .id(toast.id)
                    .transition(ActionToastState.transition(reduceMotion: reduceMotion, edge: edge))
                    .task(id: toast.id) {
                        // VoiceOver users get the toast in focus, so Undo is
                        // one swipe away and nothing times out under them.
                        if !state.dismissesAutomatically {
                            messageIsFocused = true
                        }
                    }
                    // An update keeps focus on the toast but isn't read on its own, so a
                    // VoiceOver user waiting on a busy toast hears its result.
                    .onChange(of: toast.tone) { oldTone, tone in
                        guard oldTone == .busy, tone != .busy, !state.dismissesAutomatically else { return }
                        AccessibilityNotification.Announcement(
                            ([accessibilityLabel(toast), toneValue(tone)]).joined(separator: ", ")
                        ).post()
                    }
            }
        }
        .animation(ActionToastState.animation(reduceMotion: reduceMotion), value: state.toast(at: edge)?.id)
    }

    @ViewBuilder
    private func toastBody(_ toast: ActionToast) -> some View {
        // A result can be closed early; a VoiceOver toast must be.
        let showsClose = !state.dismissesAutomatically || toast.tone == .success || toast.tone == .failure
        // A notice without controls keeps even margins.
        let hasControls = toast.actionTitle != nil || showsClose
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                message(toast)
                if hasControls {
                    HStack(spacing: 4) {
                        actionButton(toast, horizontalPadding: 0)
                        Spacer(minLength: 0)
                        if showsClose {
                            closeButton(toast)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: hasControls ? 6 : 14, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(fallbackMaterial: .regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .contain)
        } else if usesCard(toast) {
            HStack(alignment: .top, spacing: 4) {
                message(toast)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                actionButton(toast, horizontalPadding: 10)
                if showsClose {
                    closeButton(toast)
                }
            }
            .padding(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: hasControls ? 6 : 18))
            .frame(minHeight: 50)
            .adaptiveGlass(fallbackMaterial: .regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 4) {
                message(toast)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButton(toast, horizontalPadding: 10)
                if showsClose {
                    if toast.actionTitle != nil {
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 1, height: 20)
                            .accessibilityHidden(true)
                    }
                    closeButton(toast)
                }
            }
            .padding(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: hasControls ? 6 : 18))
            .frame(minHeight: 50)
            .adaptiveGlass(fallbackMaterial: .regularMaterial, in: Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    private func message(_ toast: ActionToast) -> some View {
        HStack(alignment: usesCard(toast) ? .firstTextBaseline : .center, spacing: 9) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(glyphStyle(toast.tone))
            VStack(alignment: .leading, spacing: 2) {
                // A notice has the action's room for a second line; a failure wraps to three.
                Text(toast.message)
                    .lineLimit(messageLineLimit(toast))
                ForEach(Array(toast.detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(AppFont.subheadline(weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(toast))
        .accessibilityValue(toneValue(toast.tone))
        .accessibilityFocused($messageIsFocused)
    }

    /// Lines that may wrap get a rounded card; a capsule holds one or two.
    private func usesCard(_ toast: ActionToast) -> Bool {
        !toast.detailLines.isEmpty || toast.tone == .failure
    }

    private func accessibilityLabel(_ toast: ActionToast) -> String {
        ([toast.accessibilityLabel] + toast.detailLines).joined(separator: ", ")
    }

    private func messageLineLimit(_ toast: ActionToast) -> Int? {
        if dynamicTypeSize.isAccessibilitySize { return nil }
        if toast.tone == .failure { return 3 }
        return toast.actionTitle == nil ? 2 : 1
    }

    private func glyphStyle(_ tone: ActionToast.Tone) -> Color {
        switch tone {
        case .neutral, .busy: .secondary
        case .success: .green
        case .failure: .red
        }
    }

    private func toneValue(_ tone: ActionToast.Tone) -> String {
        switch tone {
        case .neutral: ""
        case .busy: String(localized: "In progress")
        case .success: String(localized: "Done")
        case .failure: String(localized: "Failed")
        }
    }

    @ViewBuilder
    private func actionButton(_ toast: ActionToast, horizontalPadding: CGFloat) -> some View {
        if let actionTitle = toast.actionTitle {
            Button {
                state.performAction(of: toast)
            } label: {
                Text(actionTitle)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, horizontalPadding)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Ends the presentation only; work the toast reports keeps running.
    private func closeButton(_ toast: ActionToast) -> some View {
        Button {
            state.dismiss(toast.id)
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

/// Follows a sideways drag and calls `dismiss` once `ActionToastDismissPolicy`
/// says so; a shorter drag springs back. A vertical drag leaves the toast in
/// place. Under Reduce Motion the toast fades with the drag instead of moving,
/// and a short drag restores it without animating. Each toast gets its own,
/// so a dismissed toast's offset never carries into the next.
private struct ActionToastSwipe: ViewModifier {
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragWidth: CGFloat = 0
    @State private var toastWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : dragWidth)
            .opacity(reduceMotion ? 1 - min(abs(dragWidth) / max(toastWidth / 2, 1), 0.6) : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toastWidth = $0 }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragWidth = value.translation.width
                    }
                    .onEnded { value in
                        if ActionToastDismissPolicy.shouldDismiss(
                            translation: value.translation, velocity: value.velocity, width: toastWidth
                        ) {
                            dismiss()
                        } else {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { dragWidth = 0 }
                        }
                    }
            )
    }
}

/// What a share left out, for the new chat it opened (#1401). The route or chat that opened for
/// the share holds it, and the first composer to present it takes it, so a composer rebuilt for
/// that chat (a size-class change) doesn't say it again.
@MainActor final class SharedSkipsNotice {
    private var skipped: SharedSkips?

    /// Nil when the share left nothing out.
    init?(_ skipped: SharedSkips) {
        guard !skipped.isEmpty else { return nil }
        self.skipped = skipped
    }

    /// The skips the first time; nil after.
    func take() -> SharedSkips? {
        defer { skipped = nil }
        return skipped
    }
}

extension ActionToast {
    /// The notice a share's new chat shows once when the share left items out (#1401): the
    /// reason for one item, the first names and a count for several, the limit when the count
    /// limit alone left them out. Nil when nothing was left out.
    init?(sharedSkips skipped: SharedSkips) {
        guard !skipped.isEmpty else { return nil }
        let message = skipped.localizedSummary
        self.init(message: message, systemImage: "exclamationmark.triangle", accessibilityLabel: message)
    }
}
