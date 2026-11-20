import Foundation

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

    var startsTurn: Bool { self == .send || self == .queue }

    func call(runtime: String, text: String, fence: HermesCall.Fence? = nil, images: [BotUploadedImage] = [],
              titlePreview: String? = nil) -> HermesCall {
        switch self {
        case .send, .queue: return .promptSubmit(sessionID: runtime, text: text, fence: fence, images: images, titlePreview: titlePreview)
        case .steer: return .sessionSteer(sessionID: runtime, text: text, fence: fence)
        case .redirect: return .sessionRedirect(sessionID: runtime, text: text, fence: fence)
        }
    }

    func outcome(_ reply: BotJSON, turnRunning: Bool = false, canonical: Bool = false) -> BotPromptOutcome {
        if canonical, self == .send || self == .queue {
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
            if (self == .send || self == .queue), reply["voice_stopped"].flag == true { return .voiceStopped }
            return .unknown
        }
    }

    func definitelyRejected(_ error: Error) -> Bool {
        if error is HermesFenceRefusal { return true }
        guard case BotFailure.rejected(let code) = error else { return false }
        if [401, 403, 4001, 4090, -32601, -32602].contains(code) { return true }
        return (self == .steer || self == .redirect) && [4002, 4010].contains(code)
    }
}

enum BotPromptOutcome: Equatable {
    case guidanceQueued, redirected, redirectQueued, followUpQueued, started, voiceStopped, rejected, unknown
}
