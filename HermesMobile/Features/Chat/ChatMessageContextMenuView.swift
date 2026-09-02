import SwiftUI
import UIKit

/// Attaches the message action menu to a transcript bubble through UIKit's
/// `UIContextMenuInteraction` instead of SwiftUI's `.contextMenu`.
///
/// SwiftUI lifts a snapshot of the whole bubble before it can show the menu.
/// On a multi-screen reply that snapshot is slow and taller than the screen,
/// so the menu lands over the undimmed transcript and then jumps as UIKit
/// makes room. Here nothing is lifted: the transcript dims and the menu opens
/// beside the press in one motion, whatever the reply's length (issue #208).
extension View {
    /// Attach to the message content itself, not the full-width row, so the
    /// menu opens only where there is something to act on. A nil menu leaves
    /// the view untouched.
    @ViewBuilder
    func chatMessageContextMenu(_ menu: ChatMessageActionMenu?) -> some View {
        if let menu {
            background(ChatMessageContextMenuHost(menu: menu))
                .accessibilityActions {
                    ForEach(menu.items.filter(\.isEnabled)) { item in
                        Button(item.title) {
                            item.perform()
                        }
                    }
                }
        } else {
            self
        }
    }
}

private struct ChatMessageContextMenuHost: UIViewRepresentable {
    let menu: ChatMessageActionMenu

    func makeUIView(context: Context) -> ChatMessageContextMenuView {
        let view = ChatMessageContextMenuView()
        view.menu = menu
        return view
    }

    func updateUIView(_ view: ChatMessageContextMenuView, context: Context) {
        view.menu = menu
    }
}

/// A clear, touch-transparent view behind one bubble. It only marks the
/// bubble's frame and menu for the coordinator on the transcript's scroll view.
///
/// The interaction cannot live here: SwiftUI's text-selection long-press on
/// the hosting view outranks recognizers on child platform views, so a menu
/// attached to this view never fires. On the scroll view it wins, as it does
/// in a collection view.
final class ChatMessageContextMenuView: UIView {
    var menu: ChatMessageActionMenu?

    private weak var coordinator: ChatMessageContextMenuCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.unregister(self)
        coordinator = nil
        guard window != nil, let scrollView = enclosingScrollView else { return }
        let coordinator = ChatMessageContextMenuCoordinator.coordinator(for: scrollView)
        coordinator.register(self)
        self.coordinator = coordinator
    }

    private var enclosingScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }
}

/// One context-menu interaction per transcript scroll view. Rows register
/// while on screen; a long-press resolves to the row under the touch.
@MainActor
final class ChatMessageContextMenuCoordinator: NSObject, UIContextMenuInteractionDelegate {
    private static let coordinators = NSMapTable<UIScrollView, ChatMessageContextMenuCoordinator>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func coordinator(for scrollView: UIScrollView) -> ChatMessageContextMenuCoordinator {
        if let existing = coordinators.object(forKey: scrollView) {
            return existing
        }
        let coordinator = ChatMessageContextMenuCoordinator(scrollView: scrollView)
        coordinators.setObject(coordinator, forKey: scrollView)
        return coordinator
    }

    private weak var scrollView: UIScrollView?
    private let rows = NSHashTable<ChatMessageContextMenuView>.weakObjects()

    /// The row being presented and the press point inside it, which anchors
    /// the menu.
    private weak var activeRow: ChatMessageContextMenuView?
    private var pressInRow: CGPoint = .zero

    private init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        scrollView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func register(_ row: ChatMessageContextMenuView) {
        rows.add(row)
    }

    func unregister(_ row: ChatMessageContextMenuView) {
        rows.remove(row)
    }

    private func row(at location: CGPoint) -> ChatMessageContextMenuView? {
        guard let scrollView else { return nil }
        return rows.allObjects.first { row in
            row.window != nil
                && row.menu != nil
                && row.convert(row.bounds, to: scrollView).contains(location)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let scrollView, let row = row(at: location) else { return nil }
        activeRow = row
        pressInRow = row.convert(location, from: scrollView)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak row] _ in
            row?.menu?.uiMenu()
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        anchorPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        anchorPreview()
    }

    /// An invisible preview at the press point. It gives UIKit something to
    /// anchor the menu to without lifting any of the bubble; the bubble stays
    /// in place under the dim like the rest of the transcript.
    private func anchorPreview() -> UITargetedPreview? {
        guard let activeRow else { return nil }
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        anchor.backgroundColor = .clear
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        let target = UIPreviewTarget(container: activeRow, center: pressInRow)
        return UITargetedPreview(view: anchor, parameters: parameters, target: target)
    }
}
