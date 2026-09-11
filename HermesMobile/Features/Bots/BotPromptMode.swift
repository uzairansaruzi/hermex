import Foundation

/// Bot-only actions. Queue explicitly bypasses the host's configurable busy
/// input behavior, which could otherwise interrupt work started by Desktop.
enum BotPromptMode: CaseIterable, Hashable {
    case send, steer, queue, redirect

    var title: String {
        switch self {
        case .send: return String(localized: "Send")
        case .steer: return String(localized: "Steer")
        case .queue: return String(localized: "Queue")
        case .redirect: return String(localized: "Redirect")
        }
    }

    var explanation: String {
        switch self {
        case .send: return String(localized: "Start a new turn. If the bot becomes busy, wait for that work to finish.")
        case .steer: return String(localized: "Add guidance to the current work without interrupting it.")
        case .queue: return String(localized: "Run after current work, or immediately if it has finished.")
        case .redirect: return String(localized: "Interrupt current work and change direction. During startup, this may queue a follow-up.")
        }
    }

    var method: String {
        switch self {
        case .send, .queue: return "prompt.submit"
        case .steer: return "session.steer"
        case .redirect: return "session.redirect"
        }
    }

    func params(runtime: String, text: String) -> [String: BotJSON] {
        var params: [String: BotJSON] = ["session_id": .string(runtime), "text": .string(text)]
        // Even an idle Send can race Desktop. Never inherit a host setting that
        // silently converts a fresh send into a redirect or steer.
        if self == .send || self == .queue { params["queued"] = .bool(true) }
        return params
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

enum BotPromptOutcome: Equatable {
    case guidanceQueued, redirected, redirectQueued, followUpQueued, started, voiceStopped, rejected, unknown

    var receipt: String? {
        switch self {
        case .guidanceQueued: return String(localized: "Guidance queued. The bot may not have read it yet.")
        case .redirected: return String(localized: "Redirect accepted.")
        case .redirectQueued: return String(localized: "Redirect queued for the next turn during startup.")
        case .followUpQueued: return String(localized: "Follow-up queued. Stop can cancel queued work.")
        case .started: return String(localized: "Message accepted. Starting work.")
        case .voiceStopped: return String(localized: "Speech stopped. No new message was started.")
        case .rejected, .unknown: return nil
        }
    }
}
