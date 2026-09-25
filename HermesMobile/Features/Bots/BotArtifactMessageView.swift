import SwiftUI

/// Settled Bot rows render through the cached Markdown path. The live reply uses
/// the streaming renderer without its reveal fade: it bypasses the shared layout
/// cache, chunks sealed past 6,000 characters skip re-layout, and code in the
/// growing part stays plain until the reply settles.
/// Reuse the transcript parser; only the download and preview ownership are Bot-specific.
struct BotArtifactMessageView: View {
    let message: ChatMessage
    let model: BotConversation
    /// The live turn's reply. Selection stays off it: the document would be
    /// rebuilt on every snapshot, and there is nothing settled to select yet.
    var isLive = false
    /// The time for the reply footer, set only on settled user messages and
    /// turn-ending replies (`BotTranscriptTimes`). Nil draws no footer.
    var footerTime: Double? = nil
    @State private var responseIsVisible = false
    @State private var preview: TranscriptMediaPreviewItem?
    @State private var previewContext: BotArtifactContext?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
            content
            // Outside ResponseTextSelection, so the footer never joins a selection.
            if let footerTime {
                BotReplyFooter(isUserMessage: message.role == "user", timestamp: footerTime)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let completion = BotDelegationCompletion(message) {
                BotDelegationCompletionCard(completion: completion)
            } else if message.role == "user" {
                MessageBubbleView(
                    message: message,
                    transcriptMediaCacheNamespace: "\(model.server.absoluteString)|bot:\(model.connection.id.uuidString)",
                    contextMenuActions: actions,
                    textOnly: true
                )
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
        .environment(\.openURL, OpenURLAction { url in
            if let path = try? BotArtifactReference.path(url.absoluteString, address: model.connection.address) {
                previewContext = model.artifactContext
                preview = TranscriptMediaPreviewItem(reference: TranscriptMediaReference(rawReference: path))
                return .handled
            }
            return .systemAction
        })
        .sheet(item: $preview) { item in
            BotArtifactPreview(reference: item.reference) {
                guard let context = previewContext else { throw BotFailure.stale }
                return try await model.artifactData(path: item.reference.rawReference, context: context)
            }
        }
        .onChange(of: model.artifactContext) { _, _ in preview = nil; previewContext = nil }
    }

    /// Attached to the message content, not the row, so the gutter beside a
    /// user bubble stays inert.
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TranscriptMediaParser.segments(in: message.content ?? "", includesLocalFileLinks: true).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    MarkdownRenderer(content: text, isStreaming: isLive)
                        .environment(\.allowsStreamedTextAnimation, false)
                case .media(let reference):
                    BotArtifactRow(reference: reference, model: model) {
                        previewContext = model.artifactContext
                        preview = TranscriptMediaPreviewItem(reference: reference)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatMessageContextMenu(actions, longPress: isLive)
    }

    private var actions: [ChatMessageActionItem] {
        BotMessageActions.items(copyText: message.content, isHapticsEnabled: isHapticsEnabled)
    }
}

/// The one row under a settled Bot message, built on the Sessions meta row.
/// It carries the message's time today; reactions (#761) join it later rather
/// than adding a second row. Takes the raw timestamp so a streaming snapshot
/// never re-formats a settled row, and follows Settings → Chat → Message
/// Timestamps like Sessions.
struct BotReplyFooter: View {
    let isUserMessage: Bool
    let timestamp: Double

    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey)
    private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps

    var body: some View {
        if showsTimestamps, let time = ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: timestamp) {
            ChatMessageMetaRow(isUserMessage: isUserMessage, timeText: time, onCopy: nil)
        }
    }
}

private struct BotArtifactRow: View {
    let reference: TranscriptMediaReference
    let model: BotConversation
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
                Label(reference.displayName, systemImage: reference.isAudioCandidate ? "waveform" : (reference.isRasterImageCandidate ? "photo" : "doc"))
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.chatTactile(.thumbnail))
        .accessibilityLabel("Open attachment \(reference.accessibilityName)")
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
