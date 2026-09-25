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
    /// turn-ending replies (`BotTranscriptTimes`). The footer still draws
    /// without one when the row has reactions to show or offer.
    var footerTime: Double? = nil
    @State private var responseIsVisible = false
    @State private var preview: TranscriptMediaPreviewItem?
    @State private var previewContext: BotArtifactContext?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
            content
            // Outside ResponseTextSelection, so the footer never joins a selection.
            if !isLive {
                BotReplyFooter(isUserMessage: message.role == "user", timestamp: footerTime, reactions: reactions)
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
                    contextMenuActions: userActions,
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

    /// A prompt's long-press menu: the Tapback row, Copy, then Remove Reaction.
    /// It reads no connection state, so a tap elsewhere never rebuilds this
    /// row; a Tapback picked while the chat can't react is dropped by the model.
    private var userActions: [ChatMessageActionItem] {
        guard message.rowID != nil else { return actions }
        let reacting = BotMessageActions.Reacting(
            current: message.botReactions.first { $0.author == .user }?.emoji,
            react: react
        )
        return BotMessageActions.items(copyText: message.content, isHapticsEnabled: isHapticsEnabled, reacting: reacting)
    }

    /// The footer's reaction part. Only settled prompts and replies with a
    /// host row id take part; replies add the "…" menu that holds React.
    private var reactions: BotReplyReactions? {
        guard message.rowID != nil else { return nil }
        let isReply: Bool
        switch message.role {
        case "user": isReply = false
        case "assistant":
            guard !(message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            isReply = true
        default: return nil
        }
        return BotReplyReactions(
            reactions: message.botReactions, offersPicker: isReply,
            isEnabled: { [model, message] in model.mayReact(to: message) },
            profile: model.profile, connectionID: model.connection.id, react: react
        )
    }

    private func react(_ emoji: String?) {
        Task { await model.react(to: message, emoji: emoji) }
    }
}

/// The one row under a settled Bot message, built on the Sessions meta row:
/// replies read `[… → React][chips][time]`, prompts `[chips][time]`. Rooms
/// pass no reactions and get the time only. Takes the raw timestamp so a
/// streaming snapshot never re-formats a settled row, and follows Settings →
/// Chat → Message Timestamps like Sessions.
struct BotReplyFooter: View {
    let isUserMessage: Bool
    let timestamp: Double?
    var reactions: BotReplyReactions? = nil

    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey)
    private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps

    var body: some View {
        let time = showsTimestamps ? ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: timestamp) : nil
        if time != nil || reactions?.drawsSomething == true {
            ChatMessageMetaRow(isUserMessage: isUserMessage, timeText: time, onCopy: nil) {
                if let reactions {
                    BotReactionControls(content: reactions)
                }
            }
        }
    }
}

/// What a Bot Chat row's footer shows of its Tapbacks.
struct BotReplyReactions {
    let reactions: [BotReaction]
    /// Replies offer React in the footer's "…" menu; prompts use long-press.
    let offersPicker: Bool
    /// False while offline or while this row's `message.react` is in flight.
    /// A closure read only by the footer's controls, so a change to the
    /// connection or an in-flight write redraws footers, not whole rows.
    let isEnabled: () -> Bool
    let profile: BotProfile
    let connectionID: UUID
    /// Called with the emoji picked, or nil to remove yours.
    let react: (String?) -> Void

    var drawsSomething: Bool { offersPicker || !reactions.isEmpty }
    var mine: String? { reactions.first { $0.author == .user }?.emoji }
}

/// The footer's "…" menu with Desktop's six Tapbacks as one inline row, then
/// a chip per reaction: yours removes it, the Bot's is static.
private struct BotReactionControls: View {
    let content: BotReplyReactions

    var body: some View {
        let isEnabled = content.isEnabled()
        if content.offersPicker {
            Menu {
                Section(String(localized: "React")) {
                    Picker(String(localized: "React"), selection: Binding(get: { content.mine }, set: content.react)) {
                        ForEach(BotReaction.quickReactions, id: \.self) { emoji in
                            Label {
                                Text("React with \(emoji)")
                            } icon: {
                                Image(uiImage: ChatMessageActionItem.emojiImage(emoji))
                            }
                            .tag(emoji as String?)
                        }
                    }
                    .pickerStyle(.palette)
                    // One pick reacts and closes, like the long-press Tapback row.
                    .menuActionDismissBehavior(.enabled)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .chatMinimumHitTarget(in: Rectangle())
            }
            .foregroundStyle(.secondary)
            .disabled(!isEnabled)
            .accessibilityLabel("More")
        }
        ForEach(content.reactions, id: \.self) { reaction in
            BotReactionChip(reaction: reaction, content: content, isEnabled: isEnabled)
        }
    }
}

private struct BotReactionChip: View {
    let reaction: BotReaction
    let content: BotReplyReactions
    let isEnabled: Bool
    @ScaledMetric(relativeTo: .caption) private var faceSize: CGFloat = 13

    var body: some View {
        if reaction.author == .user {
            Button { content.react(nil) } label: {
                chip.chatMinimumHitTarget(horizontalPadding: 4, verticalPadding: 11, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(Text("\(reaction.emoji), reacted by you"))
            .accessibilityHint(Text("Removes your reaction."))
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(reaction.emoji), reacted by \(content.profile.name)"))
        }
    }

    private var chip: some View {
        let isMine = reaction.author == .user
        return HStack(spacing: 3) {
            Text(reaction.emoji)
            if !isMine {
                BotAvatarView(profile: content.profile,
                              avatar: BotAvatarStore.shared.images(connectionID: content.connectionID)[content.profile.id],
                              size: faceSize, motion: .still)
            }
        }
        .font(AppFont.caption())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isMine ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill), in: Capsule())
        .overlay {
            if isMine { Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5) }
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
