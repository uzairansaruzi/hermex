import SwiftUI

/// Settings → Interaction → Quick Replies: the one global list of chips shown
/// above the Bot Chat composer. Add, edit, delete and reorder all write straight
/// to `BotQuickReplyStore`, so the composer sees each change at once.
struct BotQuickRepliesEditorView: View {
    @AppStorage(BotQuickReplyStore.storageKey) private var storedReplies = ""
    @State private var editing: EditTarget?
    /// Owned here so deleting the last reply can leave edit mode: the Edit
    /// button hides with an empty list and would otherwise strand it active.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        let replies = BotQuickReplyStore.decode(storedReplies)
        List {
            if replies.isEmpty {
                Section {
                    ContentUnavailableView("No Quick Replies", systemImage: "text.bubble",
                                           description: Text("Add a reply, or start from a suggestion."))
                    addButton
                }
            } else {
                Section {
                    ForEach(replies) { reply in
                        Button { editing = .existing(reply) } label: {
                            Text(verbatim: reply.text)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                        }
                        .accessibilityHint(Text("Edits this reply"))
                    }
                    .onDelete { offsets in
                        var next = replies
                        next.remove(atOffsets: offsets)
                        save(next)
                    }
                    .onMove { offsets, destination in
                        var next = replies
                        next.move(fromOffsets: offsets, toOffset: destination)
                        save(next)
                    }
                    addButton
                } header: {
                    Text("Replies")
                } footer: {
                    Text("Shown above the Bot Chat composer when the draft is empty and the bot is idle. Same list on every server and bot. A tap fills the draft; it never sends.")
                }
            }

            Section {
                ForEach(BotQuickReplySuggestion.allCases) { suggestion in
                    let text = suggestion.text
                    let isAdded = replies.contains { $0.text == text }
                    Button { save(replies + [BotQuickReply(text: text)]) } label: {
                        HStack {
                            Text(verbatim: text).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if isAdded {
                                Text("Added").foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                    }
                    .disabled(isAdded)
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Adding a suggestion saves it as your own text. Edit it freely.")
            }
        }
        .navigationTitle("Quick Replies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !replies.isEmpty { EditButton() }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: replies.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
        .sheet(item: $editing) { target in
            BotQuickReplyEditSheet(target: target) { text in
                // Read fresh: the list may have changed under the open sheet.
                var current = BotQuickReplyStore.decode(storedReplies)
                switch target {
                case .new:
                    current.append(BotQuickReply(text: text))
                case .existing(let reply):
                    guard let index = current.firstIndex(where: { $0.id == reply.id }) else { return }
                    current[index].text = text
                }
                save(current)
            }
        }
    }

    private var addButton: some View {
        Button { editing = .new } label: {
            Label("Add Reply", systemImage: "plus")
        }
    }

    private func save(_ replies: [BotQuickReply]) {
        storedReplies = BotQuickReplyStore.encode(replies)
    }

    enum EditTarget: Identifiable {
        case new
        case existing(BotQuickReply)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let reply): reply.id
            }
        }
    }
}

/// The Add Reply and Edit Reply sheet. Save hands back trimmed text and is off
/// while the text is blank, so a stored reply is never empty.
private struct BotQuickReplyEditSheet: View {
    let target: BotQuickRepliesEditorView.EditTarget
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(target: BotQuickRepliesEditorView.EditTarget, onSave: @escaping (String) -> Void) {
        self.target = target
        self.onSave = onSave
        if case .existing(let reply) = target {
            _text = State(initialValue: reply.text)
        } else {
            _text = State(initialValue: "")
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Quick Reply", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($isFocused)
                } footer: {
                    Text("Text only. It fills the Bot Chat draft; a leading /skill runs as a skill when you send.")
                }
            }
            .navigationTitle(isNew ? Text("Add Reply") : Text("Edit Reply"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }
}
