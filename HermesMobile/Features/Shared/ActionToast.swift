import SwiftUI
import UIKit

struct ActionToast: Identifiable {
    enum Tone {
        case neutral
        case busy
        case success
        case failure
    }

    var id = UUID()
    let message: String
    let systemImage: String
    let accessibilityLabel: String
    var tone: Tone = .neutral
    var edge: Edge = .bottom
    var detailLines: [String] = []
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil

    static func failure(_ message: String) -> ActionToast {
        ActionToast(message: message, systemImage: "exclamationmark.triangle.fill",
                    accessibilityLabel: message, tone: .failure)
    }
}

@MainActor
@Observable
final class ActionToastState {
    static let displayDuration: Duration = .seconds(4)
    static let detailedDisplayDuration: Duration = .seconds(6)

    private(set) var toast: ActionToast?
    private(set) var dismissesAutomatically = true

    private var dismissTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let isVoiceOverRunning: @MainActor () -> Bool

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        isVoiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }
    ) {
        self.sleep = sleep
        self.isVoiceOverRunning = isVoiceOverRunning
    }

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

    func update(_ id: ActionToast.ID, to content: ActionToast) {
        guard toast?.id == id else { return }
        var updated = content
        updated.id = id
        present(updated)
    }

    func toast(at edge: Edge) -> ActionToast? {
        toast?.edge == edge ? toast : nil
    }

    func performAction(of actedOn: ActionToast) {
        guard toast?.id == actedOn.id else { return }
        dismiss()
        actedOn.action?()
    }

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

enum ActionToastDismissPolicy {
    static let flickVelocity: CGFloat = 600

    static func shouldDismiss(translation: CGSize, velocity: CGSize, width: CGFloat) -> Bool {
        guard abs(translation.width) > abs(translation.height) else { return false }
        if abs(translation.width) >= width / 4 { return true }
        return abs(velocity.width) >= flickVelocity && (velocity.width > 0) == (translation.width > 0)
    }
}

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
                        if !state.dismissesAutomatically {
                            messageIsFocused = true
                        }
                    }
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
        let showsClose = !state.dismissesAutomatically || toast.tone == .success || toast.tone == .failure
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
                            .fill(Color(.appSeparator))
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
                Text(toast.message)
                    .lineLimit(messageLineLimit(toast))
                ForEach(Array(toast.detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                }
            }
        }
        .font(AppFont.subheadline(weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(toast))
        .accessibilityValue(toneValue(toast.tone))
        .accessibilityFocused($messageIsFocused)
    }

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

    private func closeButton(_ toast: ActionToast) -> some View {
        Button {
            state.dismiss(toast.id)
        } label: {
            Image(systemName: "xmark")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

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

@MainActor final class SharedSkipsNotice {
    private var skipped: SharedSkips?

    init?(_ skipped: SharedSkips) {
        guard !skipped.isEmpty else { return nil }
        self.skipped = skipped
    }

    func take() -> SharedSkips? {
        defer { skipped = nil }
        return skipped
    }
}

extension ActionToast {
    init?(sharedSkips skipped: SharedSkips) {
        guard !skipped.isEmpty else { return nil }
        let message = Self.message(for: skipped)
        self.init(message: message, systemImage: "exclamationmark.triangle", accessibilityLabel: message)
    }

    private static func message(for skipped: SharedSkips) -> String {
        let named = skipped.items.filter { $0.reason != .overLimit }
        guard let first = named.first else {
            return String(localized: "\(skipped.count) items weren’t added. A message holds up to 10 attachments.")
        }

        let firstName = first.filename ?? "shared-file"
        if skipped.count == 1 {
            switch first.reason {
            case .tooLarge: return String(localized: "1 item wasn’t added: \(firstName) is over 20 MB.")
            case .unreadable: return String(localized: "1 item wasn’t added: \(firstName) couldn’t be read.")
            case .unsupported: return String(localized: "1 item wasn’t added: Hermex can’t attach \(firstName).")
            case .overLimit, nil: break
            }
        }

        let names = named.prefix(2).map { $0.filename ?? "shared-file" }
        let rest = skipped.count - names.count
        let list = ListFormatter.localizedString(byJoining: rest > 0 ? names + [String(localized: "\(rest) more")] : names)
        return String(localized: "\(skipped.count) items weren’t added: \(list).")
    }
}
