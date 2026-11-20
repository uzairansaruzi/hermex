import UIKit

enum ChatHapticFeedback: Equatable {
    case lightImpact
    case mediumImpact
    case selection
    case success
    case warning
}

struct BotFeedback: Equatable {
    enum Event: Equatable {
        case sent
        case approved(BotApprovalRequest.Choice)
        case answered
        case stopped
        case turnCompleted
    }

    let event: Event
    let id: Int

    init(_ event: Event, after previous: BotFeedback?) {
        self.event = event
        id = (previous?.id ?? 0) + 1
    }
}

@MainActor
enum ChatHaptics {
    typealias Performer = @MainActor (ChatHapticFeedback) -> Void

    static func messageSent(isEnabled: Bool, performer: Performer? = nil) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func assistantResponseCompleted(isEnabled: Bool, performer: Performer? = nil) {
        emit(.success, isEnabled: isEnabled, performer: performer)
    }

    static func streamCancelled(isEnabled: Bool, performer: Performer? = nil) {
        emit(.mediumImpact, isEnabled: isEnabled, performer: performer)
    }

    static func approvalSubmitted(_ choice: ApprovalChoice, isEnabled: Bool, performer: Performer? = nil) {
        switch choice {
        case .once, .session, .always:
            emit(.lightImpact, isEnabled: isEnabled, performer: performer)
        case .deny:
            emit(.warning, isEnabled: isEnabled, performer: performer)
        }
    }

    static func botFeedback(_ event: BotFeedback.Event, isEnabled: Bool, performer: Performer? = nil) {
        switch event {
        case .sent: messageSent(isEnabled: isEnabled, performer: performer)
        case .approved(let choice):
            guard let choice = ApprovalChoice(rawValue: choice.rawValue) else { return }
            approvalSubmitted(choice, isEnabled: isEnabled, performer: performer)
        case .answered: clarificationSubmitted(isEnabled: isEnabled, performer: performer)
        case .stopped: streamCancelled(isEnabled: isEnabled, performer: performer)
        case .turnCompleted: assistantResponseCompleted(isEnabled: isEnabled, performer: performer)
        }
    }

    static func approvalBypassEnabled(isEnabled: Bool, performer: Performer? = nil) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    static func clarificationSubmitted(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func configurationSelected(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func autocompleteAccepted(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func destructiveConfirmationAccepted(isEnabled: Bool, performer: Performer? = nil) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    static func disclosureToggled(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func scrolledToLatest(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func copied(isEnabled: Bool, performer: Performer? = nil) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func gitActionFinished(succeeded: Bool, isEnabled: Bool, performer: Performer? = nil) {
        emit(succeeded ? .success : .warning, isEnabled: isEnabled, performer: performer)
    }

    static func diffLineSelected(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func addedToPrompt(isEnabled: Bool, performer: Performer? = nil) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func streamingPulse(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    struct StreamingPulseThrottle: Equatable {
        static let defaultInterval: TimeInterval = 0.32

        var interval: TimeInterval = StreamingPulseThrottle.defaultInterval
        private var lastPulseAt: TimeInterval?

        mutating func shouldPulse(at now: TimeInterval) -> Bool {
            if let lastPulseAt, now - lastPulseAt < interval {
                return false
            }
            lastPulseAt = now
            return true
        }

        mutating func reset() {
            lastPulseAt = nil
        }
    }

    private static func emit(_ feedback: ChatHapticFeedback, isEnabled: Bool, performer: Performer?) {
        guard isEnabled else { return }
        (performer ?? Self.perform)(feedback)
    }

    private static func perform(_ feedback: ChatHapticFeedback) {
        switch feedback {
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
