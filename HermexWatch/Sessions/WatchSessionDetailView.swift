import SwiftUI
import UIKit
import HermexWatchRoot
import WatchShared

struct WatchSessionDetailView: View {
    @Bindable var model: WatchRootModel
    let session: WatchSessionSummary

    @State private var blocks: [WatchTranscriptBlock] = []
    @State private var didLoadTranscript = false
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !didLoadTranscript {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(blocks, id: \.watchID) { block in
                    transcriptRow(block)
                }
                if didLoadTranscript, blocks.isEmpty, !loadFailed {
                    Text("No messages yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                // Only this screen's own failure. A task, skill or send error
                // from elsewhere used to show up as a red line in the chat.
                if loadFailed {
                    VStack(spacing: 6) {
                        Label(WatchRootModel.errorCopy(for: "transcriptUnavailable"), systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Button("Try again") {
                            Task { await reload() }
                        }
                        .buttonBorderShape(.capsule)
                    }
                    .frame(maxWidth: .infinity)
                }
                WatchSpeakControls(
                    model: model,
                    session: session,
                    listenText: WatchTranscriptPreview.lastAssistantReply(in: blocks)
                )
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Open on the newest message and the reply controls, like Messages.
        .defaultScrollAnchor(.bottom)
        .navigationTitle(session.title)
        .onAppear { model.focus(session) }
        // Reloads when this session's row changes (a reply landed, a run
        // started or ended), not on every list refresh. `task(id:)` cancels the
        // previous load, so a slow transcript never overwrites a newer one.
        .task(id: reloadToken) { await reload() }
    }

    private var reloadToken: String {
        let current = model.session(for: session.key)
        let stamp = current?.updatedAt?.timeIntervalSince1970 ?? 0
        return "\(stamp)|\(current?.runState?.rawValue ?? "idle")"
    }

    private func reload() async {
        let loaded = await model.transcript(for: session)
        guard !Task.isCancelled else { return }
        let failed = model.lastErrorCode == "transcriptUnavailable"
        loadFailed = failed
        // A repeated server message id must not give two rows one identity.
        var seen = Set<String>()
        if !failed || blocks.isEmpty { blocks = loaded.filter { seen.insert($0.watchID).inserted } }
        didLoadTranscript = true
    }

    @ViewBuilder
    private func transcriptRow(_ block: WatchTranscriptBlock) -> some View {
        switch block {
        case .text(_, let role, let text):
            messageBubble(text, isUser: role == .user)
        case .code(_, let language, let text, let isTruncated):
            VStack(alignment: .leading, spacing: 2) {
                // The phone already drops "text"-style fence labels, so a label
                // here always names a real language.
                if let language, !language.isEmpty {
                    Text(verbatim: language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // Code cannot reflow, so let it shrink a little rather than
                // break one long token across four rows.
                Text(verbatim: text)
                    .font(.system(.caption2, design: .monospaced))
                    .minimumScaleFactor(0.8)
                    .lineLimit(12)
                if isTruncated {
                    Text("More on iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .tool(_, let title, let state, _):
            Label {
                Text(state.isEmpty ? title : "\(title) · \(state)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityLabel("Tool \(title), \(state)")
        case .image(_, let descriptor, let alt):
            WatchTranscriptImageRow(model: model, descriptor: descriptor, alt: alt)
        case .unsupported(_, let kind, let summary):
            Text("\(friendlyKind(kind)): \(summary)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Same shape as the iPhone chat: your messages are gray bubbles on the
    /// right (`systemGray3` in dark), Hermes replies are plain text on the left.
    @ViewBuilder
    private func messageBubble(_ text: String, isUser: Bool) -> some View {
        if isUser {
            WatchMarkdownText(text: text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color(red: 0.28, green: 0.28, blue: 0.29),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(WatchTranscriptProjection.plainText(text))")
        } else {
            WatchMarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                // Kept as a container so headings and links stay individually
                // navigable instead of collapsing into one flat string.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Hermes")
        }
    }

    private func friendlyKind(_ kind: String) -> String {
        switch kind {
        case "image": return "Image"
        case "audio": return "Audio"
        case "file": return "File"
        default: return kind
        }
    }
}

private extension WatchTranscriptBlock {
    /// The phone's block id, unique within one transcript page; stable across
    /// reloads so a new message does not rebuild every row above it.
    var watchID: String {
        switch self {
        case .text(let id, _, _), .code(let id, _, _, _), .tool(let id, _, _, _),
             .image(let id, _, _), .unsupported(let id, _, _):
            return id
        }
    }
}

private struct WatchTranscriptImageRow: View {
    let model: WatchRootModel
    let descriptor: WatchMediaDescriptor
    let alt: String?

    @State private var bytes: Data?

    var body: some View {
        Group {
            if let bytes, let image = UIImage(data: bytes) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(alt ?? "Image")
            } else {
                Text(alt ?? "Image — open on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            bytes = await model.mediaBytes(for: descriptor)
        }
    }
}
