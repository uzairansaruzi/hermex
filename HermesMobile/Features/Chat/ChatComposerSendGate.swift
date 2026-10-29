import Foundation

/// Decides whether the composer's Send/Stop action button is disabled.
/// Send is allowed when the user typed something, added a quote, or staged at
/// least one attachment. Attachment-only sends synthesize their message text in
/// `PendingAttachment.chatMessageText`; a send block always disables.
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
        block: ChatComposerSendBlock?
    ) -> Bool {
        block != nil || (!hasText && !hasQuotes && !hasStagedAttachments)
    }
}

/// Work in progress that holds Send even with a draft to send. VoiceOver reads it
/// as a dimmed Send's value, so the user knows what they are waiting for.
enum ChatComposerSendBlock: Equatable {
    case sending
    case compressingSession
    case uploadingAttachment
    case updatingConfiguration

    /// The first busy flag that holds Send, or nil when none does.
    init?(isSending: Bool, isCompressingSession: Bool, isUploadingAttachment: Bool, isUpdatingConfiguration: Bool) {
        if isSending {
            self = .sending
        } else if isCompressingSession {
            self = .compressingSession
        } else if isUploadingAttachment {
            self = .uploadingAttachment
        } else if isUpdatingConfiguration {
            self = .updatingConfiguration
        } else {
            return nil
        }
    }

    /// The composer status line's wording for the same work.
    var accessibilityValue: String {
        switch self {
        case .sending: String(localized: "Sending…")
        case .compressingSession: String(localized: "Compressing context...")
        case .uploadingAttachment: String(localized: "Uploading attachment...")
        case .updatingConfiguration: String(localized: "Updating composer settings...")
        }
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
    /// while the circle is Stop. The composer dispatches exactly this, so the
    /// glyph never says one behavior while a tap does another.
    let runningBehavior: StreamingSendBehavior?
    /// A Hermes session with files staged (#1012): only a fresh turn takes them, so Steer
    /// drops out and a Steer default queues them. Stop and send stays, text-only, and
    /// leaves them staged. Files alone are a draft too (#1367): mid-run they queue under
    /// every default, with nothing else to choose.
    let stagedFilesDropSteer: Bool
    private let queuesStagedFilesOnly: Bool

    init(isWaitingForStream: Bool, hasText: Bool, hasQuotes: Bool, defaultBehavior: StreamingSendBehavior,
         stagedFilesDropSteer: Bool = false) {
        showsStop = ChatComposerSendGate.showsStopButton(
            isWaitingForStream: isWaitingForStream, hasText: hasText, hasQuotes: hasQuotes
        ) && !stagedFilesDropSteer
        queuesStagedFilesOnly = stagedFilesDropSteer && !hasText && !hasQuotes
        let behavior: StreamingSendBehavior =
            stagedFilesDropSteer && (queuesStagedFilesOnly || defaultBehavior == .steer) ? .queue : defaultBehavior
        runningBehavior = isWaitingForStream && !showsStop ? behavior : nil
        self.stagedFilesDropSteer = stagedFilesDropSteer
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

    /// The long-press choices, in the Bot card's order. On a webui session, staged
    /// files keep Steer: a steer carries them as an attached-files note (#856).
    var choices: [StreamingSendBehavior] {
        guard runningBehavior != nil, !queuesStagedFilesOnly else { return [] }
        return stagedFilesDropSteer ? [.queue, .interrupt] : [.steer, .queue, .interrupt]
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

/// Device-local presentation choices shared by Sessions servers, never Bot Chat.
enum SessionChatPreferences {
    static let dismissKeyboardKey = "sessionChat.dismissKeyboardAfterSend"
    static let completionPositionKey = "sessionChat.completionPosition"

    enum CompletionPosition: String, CaseIterable {
        case latest
        case beginning

        static func storedValue(_ rawValue: String) -> Self {
            Self(rawValue: rawValue) ?? .latest
        }

        var title: String {
            switch self {
            case .latest: String(localized: "Keep at latest content")
            case .beginning: String(localized: "Show beginning of completed response")
            }
        }
    }
}

/// An asynchronous send must not overwrite a newer editing session or draft.
enum ChatSendFocusPolicy {
    static func focusAfterSubmission(
        succeeded: Bool, dismissKeyboard: Bool, wasFocused: Bool,
        submittedRevision: Int, currentRevision: Int, hasNewDraft: Bool
    ) -> Bool? {
        guard succeeded, submittedRevision == currentRevision, !hasNewDraft else { return nil }
        return dismissKeyboard ? false : wasFocused
    }
}
