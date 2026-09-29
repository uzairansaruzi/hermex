import Foundation

/// Bot-only actions. Send is the only choice while the bot is idle; the other
/// three are offered when a send lands on a working bot. Queue explicitly
/// bypasses the host's configurable busy input behavior, which could otherwise
/// interrupt work started by Desktop.
enum BotPromptMode: CaseIterable, Hashable, SendChoice {
    case send, steer, queue, redirect

    var title: String {
        switch self {
        case .send: return String(localized: "Send")
        case .steer: return String(localized: "Steer")
        case .queue: return String(localized: "Queue")
        case .redirect: return String(localized: "Interrupt")
        }
    }

    var systemImage: String {
        switch self {
        case .send: return "arrow.up"
        case .steer: return "arrow.turn.up.right"
        case .queue: return "text.append"
        case .redirect: return "stop.circle"
        }
    }

    /// What a send can mean while the bot is working, in the order the card
    /// lists them. Steer drops out when the draft carries attachments, which
    /// the host only accepts on a fresh turn.
    static func busyChoices(hasAttachments: Bool) -> [BotPromptMode] {
        hasAttachments ? [.queue, .redirect] : [.steer, .queue, .redirect]
    }

    /// Whether this mode starts a fresh turn. Only there will the host expand a
    /// skill invocation, so it is also the only place the `/` panel opens.
    var startsTurn: Bool { self == .send || self == .queue }

    /// Send and Queue both submit a queued prompt; see `HermesCall.promptSubmit`.
    func call(runtime: String, text: String) -> HermesCall {
        switch self {
        case .send, .queue: return .promptSubmit(sessionID: runtime, text: text)
        case .steer: return .sessionSteer(sessionID: runtime, text: text)
        case .redirect: return .sessionRedirect(sessionID: runtime, text: text)
        }
    }

    func outcome(_ reply: BotJSON) -> BotPromptOutcome {
        switch (self, reply["status"].text) {
        case (.steer, "queued"): return .guidanceQueued
        case (.redirect, "redirected"): return .redirected
        case (.redirect, "queued"): return .redirectQueued
        case (.send, "queued"), (.queue, "queued"): return .followUpQueued
        case (.send, "streaming"), (.queue, "streaming"): return .started
        case (.steer, "rejected"), (.redirect, "rejected"): return .rejected
        default:
            // The installed submit handler recognizes voice-stop phrases before
            // starting a turn. That acknowledgment must not claim a prompt ran.
            if (self == .send || self == .queue), reply["voice_stopped"].flag == true { return .voiceStopped }
            return .unknown
        }
    }

    func definitelyRejected(_ error: Error) -> Bool {
        guard case BotFailure.rejected(let code) = error else { return false }
        if [401, 403, 4001, 4090, -32601, -32602].contains(code) { return true }
        return (self == .steer || self == .redirect) && [4002, 4010].contains(code)
    }
}

/// What the host said about a prompt. Only `rejected` and `unknown` change what
/// the app does; the rest confirm admission and clear the draft. Nothing here is
/// shown: the transcript's own activity is the receipt.
enum BotPromptOutcome: Equatable {
    case guidanceQueued, redirected, redirectQueued, followUpQueued, started, voiceStopped, rejected, unknown
}
