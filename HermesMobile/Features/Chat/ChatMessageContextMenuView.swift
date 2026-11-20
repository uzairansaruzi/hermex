import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func chatMessageContextMenu(_ actions: [ChatMessageActionItem], longPress: Bool = true) -> some View {
        if actions.isEmpty {
            self
        } else {
            background { if longPress { ChatMessageContextMenuHost(actions: actions) } }
                .accessibilityActions {
                    ForEach(actions.filter(\.isEnabled)) { item in
                        Button(item.title) {
                            item.perform()
                        }
                    }
                }
        }
    }
}

private struct ChatMessageContextMenuHost: UIViewRepresentable {
    let actions: [ChatMessageActionItem]

    func makeUIView(context: Context) -> ChatMessageContextMenuView {
        let view = ChatMessageContextMenuView()
        view.actions = actions
        return view
    }

    func updateUIView(_ view: ChatMessageContextMenuView, context: Context) {
        view.actions = actions
    }
}

final class ChatMessageContextMenuView: UIView {
    var actions: [ChatMessageActionItem] = []

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
                && !row.actions.isEmpty
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
            row?.actions.uiMenu()
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
