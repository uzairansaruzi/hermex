import Foundation

/// Decides whether the composer's Send/Stop action button is disabled.
/// Send is allowed when the user typed something, added a quote, or staged at
/// least one attachment. Attachment-only sends synthesize their message text in
/// `PendingAttachment.chatMessageText`; the busy flags always disable.
enum ChatComposerSendGate {
    static func showsStopButton(
        isWaitingForStream: Bool,
        hasText: Bool,
        hasQuotes: Bool
    ) -> Bool {
        isWaitingForStream && !hasText && !hasQuotes
    }

    static func isDisabled(
        hasText: Bool,
        hasQuotes: Bool = false,
        hasStagedAttachments: Bool,
        isSending: Bool,
        isCompressingSession: Bool,
        isUploadingAttachment: Bool,
        isUpdatingConfiguration: Bool
    ) -> Bool {
        guard !isSending, !isCompressingSession, !isUploadingAttachment, !isUpdatingConfiguration else {
            return true
        }

        return !hasText && !hasQuotes && !hasStagedAttachments
    }
}

/// The Sessions composer's trailing circle. Stop while a response runs and the
/// draft is empty; otherwise Send. Mid-run a tap on Send uses the Send While
/// Responding default, the glyph and VoiceOver label say which behavior that
/// is, and a long-press (or a VoiceOver action) picks any behavior for this one
/// message. Idle, Send is a plain send with no choices.
struct ChatComposerSendButton: Equatable {
    let showsStop: Bool
    /// What a tap on Send does to the running response; nil while idle or
    /// while the circle is Stop.
    let runningBehavior: StreamingSendBehavior?

    init(isWaitingForStream: Bool, hasText: Bool, hasQuotes: Bool, defaultBehavior: StreamingSendBehavior) {
        showsStop = ChatComposerSendGate.showsStopButton(
            isWaitingForStream: isWaitingForStream, hasText: hasText, hasQuotes: hasQuotes
        )
        runningBehavior = isWaitingForStream && !showsStop ? defaultBehavior : nil
    }

    /// The circle's one SF Symbol: Stop, the running default's symbol, or the
    /// plain arrow.
    var systemName: String {
        if showsStop { return "stop.fill" }
        return runningBehavior?.systemImage ?? "arrow.up"
    }

    var accessibilityLabel: String {
        if showsStop { return String(localized: "Stop response") }
        return runningBehavior?.settingsDescription ?? String(localized: "Send")
    }

    /// The long-press choices, in the Bot card's order. Unlike Bots, staged
    /// files keep Steer: a steer carries them as an attached-files note (#856).
    var choices: [StreamingSendBehavior] {
        runningBehavior == nil ? [] : [.steer, .queue, .interrupt]
    }
}

/// Keeps a hold on Send from also counting as a tap. A hold that opens the
/// send-choice card marks its own release to be dropped. A new touch-down, the
/// dropped release, or the card closing after the finger lifted clears the mark.
struct ChatComposerSendHold {
    private var holdOpenedChoices = false

    /// A new touch-down on Send: any earlier hold is over.
    mutating func pressBegan() {
        holdOpenedChoices = false
    }

    /// The hold timer fired and opened the card.
    mutating func openedChoices() {
        holdOpenedChoices = true
    }

    /// The card closed. A finger still down keeps its release dropped; one
    /// that lifted off the button never reached Send, so the mark goes.
    mutating func choicesClosed(isPressing: Bool) {
        if !isPressing {
            holdOpenedChoices = false
        }
    }

    /// Send's Button action: a tap, a keyboard or assistive activation, or a
    /// hold's release. Returns whether Send should act; a hold's release does not.
    mutating func activate() -> Bool {
        guard holdOpenedChoices else { return true }
        holdOpenedChoices = false
        return false
    }
}
