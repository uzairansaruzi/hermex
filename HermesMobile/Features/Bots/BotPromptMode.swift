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

    /// Whether this mode starts a fresh turn. Only there will the host expand a
    /// skill invocation, so it is also the only place the `/` panel opens.
    var startsTurn: Bool { self == .send || self == .queue }

    /// Send and Queue both submit a queued prompt; see `HermesCall.promptSubmit`. `fence` goes
    /// only to a canonical host (#1602).
    func call(runtime: String, text: String, fence: HermesCall.Fence? = nil) -> HermesCall {
        switch self {
        case .send, .queue: return .promptSubmit(sessionID: runtime, text: text, fence: fence)
        case .steer: return .sessionSteer(sessionID: runtime, text: text, fence: fence)
        case .redirect: return .sessionRedirect(sessionID: runtime, text: text, fence: fence)
        }
    }

    /// What the host's reply says about this prompt. A `canonical` host answers a send with an
    /// admission receipt (#1602), `queued` even on an idle session, where it starts at once:
    /// `turnRunning` tells a follow-up from a start. A reply naming no admission, or any other
    /// receipt, claims nothing ran.
    func outcome(_ reply: BotJSON, turnRunning: Bool = false, canonical: Bool = false) -> BotPromptOutcome {
        if canonical, self == .send || self == .queue {
            // A stop phrase in a voice chat ends voice mode and admits nothing.
            if reply["voice_stopped"].flag == true { return .voiceStopped }
            guard reply["admission_id"].text?.isEmpty == false else { return .unknown }
            switch reply["status"].text {
            case "queued": return turnRunning ? .followUpQueued : .started
            case "started": return .started
            default: return .unknown
            }
        }
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
        // A newer turn refused it before anything took effect.
        if error is HermesStaleGeneration { return true }
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
