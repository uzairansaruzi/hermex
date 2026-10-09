import SwiftUI

/// Settled Bot rows render through the cached Markdown path. The live reply uses
/// the streaming renderer: it bypasses the shared layout cache, chunks sealed
/// past 6,000 characters skip re-layout, and code in the growing part stays
/// plain until the reply settles.
/// Reuse the transcript parser; only the download and preview ownership are Bot-specific.
struct BotArtifactMessageView: View {
    let message: ChatMessage
    let model: BotConversation
    /// The live turn's reply. Selection stays off it: the document would be
    /// rebuilt on every snapshot, and there is nothing settled to select yet.
    var isLive = false
    /// The time for the reply footer, set only on settled user messages and
    /// turn-ending replies (`BotTranscriptTimes`). The footer still draws
    /// without one when the row has Copy.
    var footerTime: Double? = nil
    /// BotChatView's `transcriptLinks` router, which opens every link this row
    /// does not own.
    @Environment(\.openURL) private var openURL
    @State private var responseIsVisible = false
    @State private var preview: TranscriptMediaPreviewItem?
    @State private var previewContext: BotArtifactContext?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
            content
            // Outside ResponseTextSelection, so the footer never joins a selection.
            if !isLive {
                BotReplyFooter(isUserMessage: message.role == "user", timestamp: footerTime, onCopy: footerCopy)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let completion = BotDelegationCompletion(message) {
                BotDelegationCompletionCard(completion: completion)
            } else if message.role == "user" {
                userContent
            } else if isLive {
                assistantContent
            } else {
                ResponseTextSelection(
                    identity: message.content ?? message.id,
                    collectsGlyphs: responseIsVisible,
                    onAskHermex: { model.quotePassage($0) }
                ) {
                    assistantContent
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
                    return viewport.intersects(CGRect(origin: .zero, size: geometry.size))
                } action: { responseIsVisible = $0 }
            }
        }
        // Artifact links can be http(s), so the row checks them first and hands
        // the rest to the chat's one `transcriptLinks` router.
        .environment(\.openURL, OpenURLAction { url in
            guard let path = try? BotArtifactReference.path(url.absoluteString, address: model.connection.address) else {
                openURL(url)
                return .handled
            }
            previewContext = model.artifactContext
            preview = TranscriptMediaPreviewItem(reference: TranscriptMediaReference(rawReference: path))
            return .handled
        })
        .sheet(item: $preview) { item in
            BotArtifactPreview(reference: item.reference) {
                guard let context = previewContext else { throw BotFailure.stale }
                return try await model.artifactData(path: item.reference.rawReference, context: context)
            }
        }
        .onChange(of: model.artifactContext) { _, _ in preview = nil; previewContext = nil }
    }

    /// A prompt as you sent it (#1017): the typed text in its bubble, then one row per
    /// attachment it referenced, opening through the Bot's download like a reply's media.
    /// An attachment-only prompt has no bubble, so its rows carry the long-press menu.
    private var userContent: some View {
        let prompt = BotPrompt(message)
        return VStack(alignment: .trailing, spacing: 8) {
            if prompt.hasText || prompt.attachments.isEmpty {
                MessageBubbleView(
                    message: prompt.message,
                    transcriptMediaCacheNamespace: "\(model.server.absoluteString)|bot:\(model.connection.id.uuidString)",
                    contextMenuActions: actions(copyText: prompt.message.content),
                    textOnly: true
                )
            }
            if !prompt.attachments.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(Array(prompt.attachments.enumerated()), id: \.offset) { _, attachment in
                        BotArtifactRow(reference: attachment.reference, model: model, title: attachment.name) {
                            previewContext = model.artifactContext
                            preview = TranscriptMediaPreviewItem(reference: attachment.reference)
                        }
                    }
                }
                .chatMessageContextMenu(prompt.hasText ? [] : actions(copyText: nil))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Attached to the message content, not the row, so the gutter beside a
    /// user bubble stays inert.
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TranscriptMediaParser.segments(in: message.content ?? "", includesLocalFileLinks: true).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    MarkdownRenderer(content: text, isStreaming: isLive)
                case .media(let reference):
                    BotArtifactRow(reference: reference, model: model) {
                        previewContext = model.artifactContext
                        preview = TranscriptMediaPreviewItem(reference: reference)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The footer button is the settled reply's sole VoiceOver Copy control.
        .chatMessageContextMenu(footerCopy == nil ? actions(copyText: message.content) : [], longPress: isLive)
    }

    private var footerCopy: (() -> Void)? {
        BotMessageActions.footerCopy(message: message, isLive: isLive, isHapticsEnabled: isHapticsEnabled)
    }

    private func actions(copyText: String?) -> [ChatMessageActionItem] {
        BotMessageActions.items(copyText: copyText, isHapticsEnabled: isHapticsEnabled)
    }
}

/// The one row under a settled Bot message, built on the Sessions meta row:
/// replies read `[Copy][time]`, prompts `[time]`. Rooms pass no Copy and get the
/// time only. Takes the raw timestamp so a streaming snapshot never re-formats a
/// settled row, and follows Settings → Chat → Message Timestamps like Sessions.
struct BotReplyFooter: View {
    let isUserMessage: Bool
    let timestamp: Double?
    var onCopy: (() -> Void)? = nil

    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey)
    private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps

    var body: some View {
        let time = showsTimestamps ? ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: timestamp) : nil
        if time != nil || onCopy != nil {
            ChatMessageMetaRow(isUserMessage: isUserMessage, timeText: time, onCopy: onCopy)
        }
    }
}

/// A Bot Chat prompt as its row shows it (#1017). The reference lines a Hermex send
/// appends (`MessageAttachment.hermesReferences`) become attachments that keep the host
/// path the Bot downloads through, and `message` keeps only the typed text, which is what
/// the bubble shows and Copy copies. A line the rule does not read stays in the text.
struct BotPrompt {
    struct Attachment {
        let name: String
        let reference: TranscriptMediaReference
    }

    let message: ChatMessage
    let attachments: [Attachment]

    var hasText: Bool { !(message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(_ message: ChatMessage) {
        guard let content = message.content else { (self.message, attachments) = (message, []); return }
        let shown = MessageAttachment.hermesReferences(in: content)
        attachments = shown.attachments.compactMap { attachment in
            guard let path = attachment.path else { return nil }
            let reference = TranscriptMediaReference(rawReference: path)
            return Attachment(name: attachment.name ?? reference.displayName, reference: reference)
        }
        self.message = shown.text == content ? message : ChatMessage(
            role: message.role, content: shown.text, timestamp: message.timestamp, messageId: message.messageId,
            name: message.name, toolCallId: message.toolCallId, toolUseId: message.toolUseId,
            toolCalls: message.toolCalls, contentParts: message.contentParts, reasoning: message.reasoning,
            attachments: message.attachments, displayKind: message.displayKind, displayMetadata: message.displayMetadata,
            turnTps: message.turnTps, turnDuration: message.turnDuration, rowID: message.rowID
        )
    }
}

private struct BotArtifactRow: View {
    let reference: TranscriptMediaReference
    let model: BotConversation
    /// The row's label; a reply's media shows its file name.
    var title: String? = nil
    let open: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 210, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Label(title ?? reference.displayName, systemImage: reference.isAudioCandidate ? "waveform" : (reference.isRasterImageCandidate ? "photo" : "doc"))
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.chatTactile(.thumbnail))
        .accessibilityLabel("Open attachment \(title ?? reference.accessibilityName)")
        .task(id: LoadIdentity(context: model.artifactContext, reference: reference.rawReference)) {
            image = nil
            guard reference.isRasterImageCandidate, let context = model.artifactContext,
                  let data = try? await model.artifactData(path: reference.rawReference, context: context),
                  let thumbnail = await ImagePreviewDownsampler.previewDataAsync(from: data, maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize),
                  !Task.isCancelled, context == model.artifactContext else { return }
            image = UIImage(data: thumbnail)
        }
    }

    private struct LoadIdentity: Hashable {
        let context: BotArtifactContext?
        let reference: String
    }
}
