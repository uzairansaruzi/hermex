import UIKit

enum ChatHapticFeedback: Equatable {
    case lightImpact
    case mediumImpact
    case selection
    case success
    case warning
}

@MainActor
enum ChatHaptics {
    typealias Performer = @MainActor (ChatHapticFeedback) -> Void

    static func messageSent(isEnabled: Bool, performer: Performer = perform) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func messageCopied(isEnabled: Bool, performer: Performer = perform) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    static func assistantResponseCompleted(isEnabled: Bool, performer: Performer = perform) {
        emit(.success, isEnabled: isEnabled, performer: performer)
    }

    static func streamCancelled(isEnabled: Bool, performer: Performer = perform) {
        emit(.mediumImpact, isEnabled: isEnabled, performer: performer)
    }

    static func approvalSubmitted(_ choice: ApprovalChoice, isEnabled: Bool, performer: Performer = perform) {
        switch choice {
        case .once, .session, .always:
            emit(.lightImpact, isEnabled: isEnabled, performer: performer)
        case .deny:
            emit(.warning, isEnabled: isEnabled, performer: performer)
        }
    }

    static func approvalBypassEnabled(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    static func clarificationSubmitted(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func configurationSelected(isEnabled: Bool, performer: Performer = perform) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    static func destructiveConfirmationAccepted(isEnabled: Bool, performer: Performer = perform) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    private static func emit(_ feedback: ChatHapticFeedback, isEnabled: Bool, performer: Performer) {
        guard isEnabled else { return }
        performer(feedback)
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
