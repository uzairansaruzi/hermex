import Foundation

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

struct ChatComposerAccess: Equatable {
    let readOnlyMessage: String?
    let isOffline: Bool
    let offersWaitingSend: Bool
    let hasWaitingSend: Bool

    init(session: SessionSummary, isViewingCachedData: Bool, offersWaitingSend: Bool = false, hasWaitingSend: Bool = false) {
        readOnlyMessage = session.isSessionReadOnly ? String(localized: "Read-only") : nil
        isOffline = isViewingCachedData
        self.offersWaitingSend = offersWaitingSend && readOnlyMessage == nil
        self.hasWaitingSend = hasWaitingSend
    }

    var allowsEditing: Bool { readOnlyMessage == nil }

    func holdsSendOffline(isPlainText: Bool) -> Bool {
        isOffline && !(offersWaitingSend && isPlainText)
    }

    var allowsHostControls: Bool { allowsEditing && !isOffline }
}

enum ChatComposerNewChatPolicy {
    static func showsControls(hasMessages: Bool, serverMessageCount: Int?, isStreaming: Bool) -> Bool {
        !hasMessages && (serverMessageCount ?? 0) == 0 && !isStreaming
    }
}

struct ChatComposerControlGate {
    let access: ChatComposerAccess
    let isSending: Bool
    let isCompressingSession: Bool
    let isWaitingForStream: Bool
    let isUpdatingConfiguration: Bool

    var allowsAttaching: Bool { access.allowsHostControls }

    var allowsConfiguration: Bool {
        allowsConfigurationIgnoringUpdates && !isUpdatingConfiguration
    }

    var allowsConfigurationIgnoringUpdates: Bool {
        access.allowsHostControls && !isSending && !isCompressingSession && !isWaitingForStream
    }

    func allowsModelSettings(approvals: ComposerApprovals?) -> Bool {
        allowsConfiguration || (access.allowsHostControls && approvals?.canTurnOffYolo == true)
    }
}

enum ChatComposerSendBlock: Equatable {
    case waitingForConnection
    case offline
    case sending
    case compressingSession
    case uploadingAttachment
    case updatingConfiguration

    init?(isWaitingForConnection: Bool = false, isOffline: Bool, isSending: Bool, isCompressingSession: Bool,
          isUploadingAttachment: Bool, isUpdatingConfiguration: Bool) {
        if isWaitingForConnection {
            self = .waitingForConnection
        } else if isOffline {
            self = .offline
        } else if isSending {
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

    var accessibilityValue: String {
        switch self {
        case .waitingForConnection: String(localized: "Waiting for connection")
        case .offline: String(localized: "Reconnect to send messages.")
        case .sending: String(localized: "Sending…")
        case .compressingSession: String(localized: "Compressing context...")
        case .uploadingAttachment: String(localized: "Uploading attachment...")
        case .updatingConfiguration: String(localized: "Updating composer settings...")
        }
    }
}

struct ChatComposerSendButton: Equatable {
    let showsStop: Bool
    let runningBehavior: StreamingSendBehavior?
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

    var systemName: String {
        if showsStop { return "stop.fill" }
        return runningBehavior?.systemImage ?? "arrow.up"
    }

    var accessibilityLabel: String {
        if showsStop { return String(localized: "Stop response") }
        return runningBehavior?.settingsDescription ?? String(localized: "Send")
    }

    var choices: [StreamingSendBehavior] {
        guard runningBehavior != nil, !queuesStagedFilesOnly else { return [] }
        return stagedFilesDropSteer ? [.queue, .interrupt] : [.steer, .queue, .interrupt]
    }

    var alternateBehavior: StreamingSendBehavior? {
        choices.first { $0 != runningBehavior && $0 != .interrupt }
    }
}

struct ChatComposerSendHold {
    private var holdOpenedChoices = false

    mutating func pressBegan() {
        holdOpenedChoices = false
    }

    mutating func openedChoices() {
        holdOpenedChoices = true
    }

    mutating func choicesClosed(isPressing: Bool) {
        if !isPressing {
            holdOpenedChoices = false
        }
    }

    mutating func activate() -> Bool {
        guard holdOpenedChoices else { return true }
        holdOpenedChoices = false
        return false
    }
}

enum SessionChatPreferences {
    static let dismissKeyboardKey = "sessionChat.dismissKeyboardAfterSend"
    static let returnSendsKey = "sessionChat.returnSends"
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

enum ChatSendFocusPolicy {
    static func focusAfterSubmission(
        succeeded: Bool, dismissKeyboard: Bool, wasFocused: Bool,
        submittedRevision: Int, currentRevision: Int, hasNewDraft: Bool
    ) -> Bool? {
        guard succeeded, submittedRevision == currentRevision, !hasNewDraft else { return nil }
        return dismissKeyboard ? false : wasFocused
    }
}
