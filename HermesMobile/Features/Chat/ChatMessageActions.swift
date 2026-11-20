import SwiftUI
import UIKit

struct SelectableTextPresentation: Identifiable, Equatable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

}

struct ChatMessageActionItem: Identifiable {
    enum Kind: Hashable {
        case listen
        case regenerate
        case edit
        case fork
        case copy
    }

    let kind: Kind
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let perform: () -> Void

    var id: Kind { kind }
}

extension Array where Element == ChatMessageActionItem {
    @MainActor
    func uiMenu() -> UIMenu {
        UIMenu(children: map { item in
            let action = UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in
                item.perform()
            }
            if !item.isEnabled {
                action.attributes = .disabled
            }
            return action
        })
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

    var items: [ChatMessageActionItem] {
        var items: [ChatMessageActionItem] = []
        let offersHistoryActions = context.offersHistoryActions

        if context.role == .assistant {
            items.append(ChatMessageActionItem(
                kind: .listen,
                title: isListening ? String(localized: "Stop Listening") : String(localized: "Listen"),
                systemImage: isListening ? "speaker.slash" : "speaker.wave.2",
                isEnabled: true,
                perform: { onToggleListening(context) }
            ))
        }

        if context.role == .assistant, offersHistoryActions {
            items.append(ChatMessageActionItem(
                kind: .regenerate,
                title: String(localized: "Regenerate Response"),
                systemImage: "arrow.clockwise",
                isEnabled: !(isViewingCachedData || hasActiveStream || isRegeneratingMessage || isEditingMessage),
                perform: { onRegenerate(context) }
            ))
        }

        if context.role == .user, offersHistoryActions {
            items.append(ChatMessageActionItem(
                kind: .edit,
                title: String(localized: "Edit Message"),
                systemImage: "pencil",
                isEnabled: !(isViewingCachedData || hasActiveStream || isRegeneratingMessage || isEditingMessage),
                perform: { onEdit(context) }
            ))
        }

        if context.offersFork {
            items.append(ChatMessageActionItem(
                kind: .fork,
                title: String(localized: "Fork From Here"),
                systemImage: "arrow.triangle.branch",
                isEnabled: !(isViewingCachedData || hasActiveStream || isForkingMessage),
                perform: { onFork(context) }
            ))
        }
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
                .background(Color(.appCanvas))
                .themedPageBackground()
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
        textView.backgroundColor = .appCanvas
        textView.font = .app(forTextStyle: .body, at: context.environment.dynamicTypeSize)
        textView.adjustsFontForContentSizeCategory = true
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

    @Binding var editDraft: String
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editDraft)
                    .font(AppFont.body())
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.appGroupedCanvas))
            }
            .themedPageBackground()
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
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
