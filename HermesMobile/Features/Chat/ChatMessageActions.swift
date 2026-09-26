import SwiftUI
import UIKit

struct SelectableTextPresentation: Identifiable, Equatable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    init(context: MessageActionContext) {
        self.init(id: context.messageID, text: context.copyText)
    }
}

/// One entry of the message action menu. The SwiftUI menu and the UIKit
/// context-menu interaction both build from this list so they never drift.
struct ChatMessageActionItem: Identifiable {
    enum Kind: Hashable {
        case listen
        case regenerate
        case edit
        case fork
        case copy
        /// One Tapback; consecutive ones form the menu's inline emoji row.
        case react(String)
        case removeReaction
    }

    let kind: Kind
    /// The menu title, and the VoiceOver name of a Tapback, which shows only its emoji.
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let perform: () -> Void
    /// Draws the item checked; the Tapback row highlights your current reaction.
    var isSelected = false

    var id: Kind { kind }

    @MainActor private static var emojiImages: [String: UIImage] = [:]

    /// A Tapback's emoji drawn as its menu image. A small-element menu row
    /// shows images only, so the item title stays free for VoiceOver.
    @MainActor
    static func emojiImage(_ emoji: String) -> UIImage {
        if let image = emojiImages[emoji] { return image }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22)]
        let text = emoji as NSString
        let image = UIGraphicsImageRenderer(size: text.size(withAttributes: attributes)).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        emojiImages[emoji] = image
        return image
    }
}

/// The long-press menu is built from the item list alone, so any transcript
/// that can name its own actions — Sessions, a Bot chat, a group room — gets
/// the same UIKit menu without owning a chat view model.
extension Array where Element == ChatMessageActionItem {
    @MainActor
    func uiMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        var tapbacks: [UIAction] = []
        func closeTapbackRow() {
            guard !tapbacks.isEmpty else { return }
            children.append(UIMenu(options: .displayInline, preferredElementSize: .small, children: tapbacks))
            tapbacks = []
        }
        for item in self {
            let image: UIImage?
            if case .react(let emoji) = item.kind {
                image = ChatMessageActionItem.emojiImage(emoji)
            } else {
                image = UIImage(systemName: item.systemImage)
            }
            let action = UIAction(title: item.title, image: image) { _ in
                item.perform()
            }
            if !item.isEnabled {
                action.attributes = .disabled
            }
            if item.isSelected {
                action.state = .on
            }
            if case .react = item.kind {
                tapbacks.append(action)
            } else {
                closeTapbackRow()
                children.append(action)
            }
        }
        closeTapbackRow()
        return UIMenu(children: children)
    }
}

struct ChatMessageActionMenu: View {
    let context: MessageActionContext
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        ForEach(items) { item in
            Button {
                item.perform()
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(!item.isEnabled)
        }
    }

    /// The actions for this message in display order. Mutating actions are
    /// disabled while the transcript is cached or a stream is active.
    var items: [ChatMessageActionItem] {
        var items: [ChatMessageActionItem] = []

        if context.role == .assistant {
            items.append(ChatMessageActionItem(
                kind: .listen,
                title: isListening ? String(localized: "Stop Listening") : String(localized: "Listen"),
                systemImage: isListening ? "speaker.slash" : "speaker.wave.2",
                isEnabled: true,
                perform: { onToggleListening(context) }
            ))
            items.append(ChatMessageActionItem(
                kind: .regenerate,
                title: String(localized: "Regenerate Response"),
                systemImage: "arrow.clockwise",
                isEnabled: !(isViewingCachedData || hasActiveStream || isRegeneratingMessage),
                perform: { onRegenerate(context) }
            ))
        }

        if context.role == .user {
            items.append(ChatMessageActionItem(
                kind: .edit,
                title: String(localized: "Edit Message"),
                systemImage: "pencil",
                isEnabled: !(isViewingCachedData || hasActiveStream || isEditingMessage),
                perform: { onEdit(context) }
            ))
        }

        items.append(ChatMessageActionItem(
            kind: .fork,
            title: String(localized: "Fork From Here"),
            systemImage: "arrow.triangle.branch",
            isEnabled: !(isViewingCachedData || hasActiveStream || isForkingMessage),
            perform: { onFork(context) }
        ))
        if context.role == .user {
            items.append(ChatMessageActionItem(
                kind: .copy,
                title: String(localized: "Copy"),
                systemImage: "doc.on.doc",
                isEnabled: true,
                perform: { onCopy(context) }
            ))
        }

        return items
    }

    /// The same actions as a UIKit menu, for `ChatMessageContextMenuView`.
    func uiMenu() -> UIMenu {
        items.uiMenu()
    }

    private var isListening: Bool {
        listeningMessageID == context.messageID
    }
}

struct SelectableTextPresentationView: View {
    let selection: SelectableTextPresentation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: selection.text)
                .accessibilityIdentifier("selectable-response-text")
                .background(Color(.systemBackground))
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .systemBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        // A wrapped UITextView does not inherit SwiftUI's layoutDirection; `.natural`
        // lets each paragraph align by its own writing direction so RTL message text
        // reads right-aligned while LTR stays left-aligned (issue #294).
        textView.textAlignment = .natural
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let originalText: String
    @Binding var editDraft: String
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editDraft)
                    .font(.body)
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        onSubmit()
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
