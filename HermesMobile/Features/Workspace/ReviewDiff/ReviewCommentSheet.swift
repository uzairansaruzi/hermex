import SwiftUI

/// The Comment… sheet on the diff and source surfaces: names the captured lines and
/// takes an optional note. Add hands the note to the host, which turns its own
/// `ReviewCommentComposer` context into draft Markdown, so a context the host already
/// dropped (a refresh) adds nothing. Cancel and swipe-down add nothing either.
struct ReviewCommentSheet: View {
    let context: ReviewCommentContext
    let onAdd: (String) -> Void

    @State private var comment = ""
    @FocusState private var isCommentFocused: Bool
    @ScaledMetric private var compactHeight: CGFloat = 190
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: heading)
                    .font(AppFont.mono(style: .caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(accessibilityHeading)
                    .accessibilityValue(Text(verbatim: context.path))
                TextField("Add a comment (optional)", text: $comment, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isCommentFocused)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(comment) }
                }
            }
            .onAppear { isCommentFocused = true }
        }
        .presentationDetents([.height(compactHeight), .medium])
        .adaptiveFormPresentation()
    }

    private var heading: String {
        guard let lines = context.lines else { return context.path }
        let range = lines.first == lines.last ? "L\(lines.first)" : "L\(lines.first)–L\(lines.last)"
        return "\(context.path) \(range)"
    }

    private var accessibilityHeading: String {
        guard let lines = context.lines else { return String(localized: "Comment") }
        if lines.first == lines.last { return String(localized: "Comment on line \(lines.first)") }
        return String(localized: "Comment on lines \(lines.first) to \(lines.last)")
    }
}

/// The selection bar's quiet state once this surface has added comments and nothing
/// is selected. Back to Chat shows only when the host can close back to the chat.
struct ReviewCommentStatusBar: View {
    let addedCount: Int
    let onReturnToChat: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(addedCount) comments added")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let onReturnToChat {
                Button(action: onReturnToChat) {
                    Text("Back to Chat")
                        .font(AppFont.footnote(weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}
