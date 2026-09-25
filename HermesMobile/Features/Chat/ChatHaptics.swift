import UIKit

enum ChatHapticFeedback: Equatable {
    case lightImpact
    case mediumImpact
    case selection
    case success
    case warning
}

/// A Bot Chat or room action the host confirmed, published by the model for its
/// view to play through `ChatHaptics.botFeedback`. Models set it only on a success
/// path that already passed their stale-reply checks. `id` grows with every event,
/// so two identical events in a row both reach the view's `onChange`.
struct BotFeedback: Equatable {
    enum Event: Equatable {
        case sent
        case approved(BotApprovalRequest.Choice)
        /// A clarify answer or skip, or a credential value or skip.
        case answered
        /// A Desktop task called off from the phone.
        case declined
        case stopped
        /// A turn this screen watched go from busy to idle.
        case turnCompleted
    }

    let event: Event
    let id: Int

    /// The event that follows `previous`, with a fresh id.
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

    /// The Sessions haptic for a confirmed Bot Chat or room event, so a bot feels
    /// the same as a session. Declining a Desktop task reads as a deny.
    static func botFeedback(_ event: BotFeedback.Event, isEnabled: Bool, performer: Performer? = nil) {
        switch event {
        case .sent: messageSent(isEnabled: isEnabled, performer: performer)
        case .approved(let choice):
            // Both enums spell the host's once/session/always/deny.
            guard let choice = ApprovalChoice(rawValue: choice.rawValue) else { return }
            approvalSubmitted(choice, isEnabled: isEnabled, performer: performer)
        case .answered: clarificationSubmitted(isEnabled: isEnabled, performer: performer)
        case .declined: approvalSubmitted(.deny, isEnabled: isEnabled, performer: performer)
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

    static func destructiveConfirmationAccepted(isEnabled: Bool, performer: Performer? = nil) {
        emit(.warning, isEnabled: isEnabled, performer: performer)
    }

    /// Any transcript disclosure: tool cards, tool groups, reasoning, marker cards.
    static func disclosureToggled(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    /// The scroll-to-latest button, a deliberate jump rather than a follow scroll.
    static func scrolledToLatest(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    /// Every pasteboard write the user asks for: messages, code blocks, files, titles, links.
    static func copied(isEnabled: Bool, performer: Performer? = nil) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    /// The `running → finished` edge of a Git action shown in the toast overlay.
    /// Call it once per action outcome, never from a view body.
    static func gitActionFinished(succeeded: Bool, isEnabled: Bool, performer: Performer? = nil) {
        emit(succeeded ? .success : .warning, isEnabled: isEnabled, performer: performer)
    }

    /// A line tapped or long-pressed on the review diff surface.
    static func diffLineSelected(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    /// Selected diff lines dropped into the composer draft.
    static func addedToPrompt(isEnabled: Bool, performer: Performer? = nil) {
        emit(.lightImpact, isEnabled: isEnabled, performer: performer)
    }

    /// One tick of the opt-in pulse while assistant text streams. Callers throttle
    /// with `StreamingPulseThrottle`; this only honors the enabled flag.
    static func streamingPulse(isEnabled: Bool, performer: Performer? = nil) {
        emit(.selection, isEnabled: isEnabled, performer: performer)
    }

    /// Rate limit for the streaming pulse: at most one tick per `interval`, so a
    /// fast token stream feels like a faint ticker instead of a buzz.
    struct StreamingPulseThrottle: Equatable {
        static let defaultInterval: TimeInterval = 0.32

        var interval: TimeInterval = StreamingPulseThrottle.defaultInterval
        private var lastPulseAt: TimeInterval?

        /// Records a token arrival. Returns `true` when enough time has passed for a pulse.
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
