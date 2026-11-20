import SwiftUI

enum TranscriptMessageMetaPolicy {
    static func showsRow(hasActions: Bool, hasTimestamp: Bool) -> Bool {
        hasActions || hasTimestamp
    }

    static func terminalReplyRenderIDs(
        transcriptMessages: [TranscriptMessage],
        messages: [ChatMessage],
        messageOffset: Int?,
        rendersBubble: (ChatMessage) -> Bool,
        isStreamActive: Bool,
        streamingAssistantMessageID: String?
    ) -> Set<String> {
        let turnKeyByAnchorID = TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
            messages,
            messageOffset: messageOffset
        )
        let unsettledTurnKey = isStreamActive
            ? TranscriptTurnClassifier.latestTurnKey(in: messages, messageOffset: messageOffset)
            : nil
        let streamingTurnKey = streamingAssistantMessageID.flatMap { turnKeyByAnchorID[$0] }

        var lastReplyByTurnKey: [String: String] = [:]
        for transcriptMessage in transcriptMessages
        where transcriptMessage.message.role == "assistant" && rendersBubble(transcriptMessage.message) {
            guard let turnKey = turnKeyByAnchorID[transcriptMessage.anchorID],
                  turnKey != unsettledTurnKey,
                  turnKey != streamingTurnKey
            else { continue }
            lastReplyByTurnKey[turnKey] = transcriptMessage.renderID
        }

        return Set(lastReplyByTurnKey.values)
    }
}

struct ChatMessageMetaRow<Accessory: View>: View {
    let isUserMessage: Bool
    let timeText: String?
    let onCopy: (() -> Void)?
    var actionMenu: ChatMessageActionMenu?
    let accessory: Accessory

    init(
        isUserMessage: Bool,
        timeText: String?,
        onCopy: (() -> Void)?,
        actionMenu: ChatMessageActionMenu? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.isUserMessage = isUserMessage
        self.timeText = timeText
        self.onCopy = onCopy
        self.actionMenu = actionMenu
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 4) {
            if isUserMessage {
                accessory
                time
                copyButton
            } else {
                copyButton
                if let actionMenu {
                    Menu { actionMenu } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .chatMinimumHitTarget(in: Rectangle())
                    }
                    .foregroundStyle(.appSecondary)
                    .accessibilityLabel("More")
                }
                accessory
                time
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    @ViewBuilder
    private var time: some View {
        if let timeText {
            Text(timeText)
                .font(AppFont.caption(weight: .medium).monospacedDigit())
                .foregroundStyle(.appSecondary)
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if let onCopy {
            ChatCopyButton(action: onCopy)
                .foregroundStyle(.appSecondary)
        }
    }
}

extension ChatMessageMetaRow where Accessory == EmptyView {
    init(isUserMessage: Bool, timeText: String?, onCopy: (() -> Void)?, actionMenu: ChatMessageActionMenu? = nil) {
        self.init(isUserMessage: isUserMessage, timeText: timeText, onCopy: onCopy, actionMenu: actionMenu) {
            EmptyView()
        }
    }
}

struct ChatCopyButton: View {
    static let feedbackDuration: Duration = .milliseconds(1200)

    var label = String(localized: "Copy")
    var copiedLabel = String(localized: "Copied")
    var size: CGFloat = 28
    var glyphSize: CGFloat = 13
    var glyphWeight: Font.Weight = .medium
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false
    @State private var copyCount = 0

    var body: some View {
        Button {
            action()
            showsCopied = true
            copyCount += 1
        } label: {
            Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: glyphSize, weight: glyphWeight))
                .frame(width: size, height: size)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .chatMinimumHitTarget(
                    horizontalPadding: max(0, (44 - size) / 2),
                    verticalPadding: max(0, (44 - size) / 2),
                    in: Rectangle()
                )
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel(showsCopied ? copiedLabel : label)
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

enum ChatMessageTimestampFormatter {
    private static let sharedFormatter: DateFormatter = makeFormatter(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    static func shortTime(forUnixTimestamp timestamp: Double?) -> String? {
        format(timestamp, with: sharedFormatter)
    }

    static func shortTime(
        forUnixTimestamp timestamp: Double?,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        format(timestamp, with: makeFormatter(locale: locale, timeZone: timeZone))
    }

    private static func makeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static func format(_ timestamp: Double?, with formatter: DateFormatter) -> String? {
        guard let timestamp, timestamp.isFinite else { return nil }
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
