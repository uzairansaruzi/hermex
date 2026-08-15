import Foundation

struct GoalSubmissionResponse: Decodable, Equatable {
    let ok: Bool?
    let action: String?
    let message: String?
    let goal: SubmittedGoal?
    let kickoffPrompt: String?
    let decision: GoalDecision?

    var displayMessage: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var kickoffPromptText: String? {
        let trimmed = kickoffPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case action
        case message
        case goal
        case kickoffPrompt
        case kickoffPromptSnake = "kickoff_prompt"
        case decision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        action = container.decodeLossyStringIfPresent(forKey: .action)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        goal = try? container.decodeIfPresent(SubmittedGoal.self, forKey: .goal)
        kickoffPrompt = container.decodeLossyStringIfPresent(forKey: .kickoffPrompt)
            ?? container.decodeLossyStringIfPresent(forKey: .kickoffPromptSnake)
        decision = try? container.decodeIfPresent(GoalDecision.self, forKey: .decision)
    }
}

struct SubmittedGoal: Decodable, Equatable {
    let goal: String?
    let status: String?
    let turnsUsed: Int?
    let maxTurns: Int?
    let lastVerdict: String?
    let lastReason: String?
    let pausedReason: String?

    init(
        goal: String?,
        status: String?,
        turnsUsed: Int? = nil,
        maxTurns: Int? = nil,
        lastVerdict: String? = nil,
        lastReason: String? = nil,
        pausedReason: String? = nil
    ) {
        self.goal = goal
        self.status = status
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
        self.lastVerdict = lastVerdict
        self.lastReason = lastReason
        self.pausedReason = pausedReason
    }

    enum CodingKeys: String, CodingKey {
        case goal
        case status
        case turnsUsed
        case turnsUsedSnake = "turns_used"
        case maxTurns
        case maxTurnsSnake = "max_turns"
        case lastVerdict
        case lastVerdictSnake = "last_verdict"
        case lastReason
        case lastReasonSnake = "last_reason"
        case pausedReason
        case pausedReasonSnake = "paused_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = container.decodeLossyStringIfPresent(forKey: .goal)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        turnsUsed = container.decodeLossyIntIfPresent(forKey: .turnsUsed)
            ?? container.decodeLossyIntIfPresent(forKey: .turnsUsedSnake)
        maxTurns = container.decodeLossyIntIfPresent(forKey: .maxTurns)
            ?? container.decodeLossyIntIfPresent(forKey: .maxTurnsSnake)
        lastVerdict = container.decodeLossyStringIfPresent(forKey: .lastVerdict)
            ?? container.decodeLossyStringIfPresent(forKey: .lastVerdictSnake)
        lastReason = container.decodeLossyStringIfPresent(forKey: .lastReason)
            ?? container.decodeLossyStringIfPresent(forKey: .lastReasonSnake)
        pausedReason = container.decodeLossyStringIfPresent(forKey: .pausedReason)
            ?? container.decodeLossyStringIfPresent(forKey: .pausedReasonSnake)
    }
}

/// Goal states currently persisted by Hermes' `GoalState` contract.
/// Unknown values remain visible instead of being mislabeled as active, so a
/// server-side addition degrades honestly while the app catches up.
enum GoalPresentationStatus: Equatable {
    case active
    case paused
    case done
    case cleared
    case unknown(String)

    init(rawValue: String?) {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "active": self = .active
        case "paused": self = .paused
        case "done": self = .done
        case "cleared": self = .cleared
        default: self = .unknown(normalized)
        }
    }

    var label: String {
        switch self {
        case .active: String(localized: "Active")
        case .paused: String(localized: "Paused")
        case .done: String(localized: "Done")
        case .cleared: String(localized: "Cleared")
        case .unknown(let raw): raw.isEmpty ? String(localized: "Goal") : raw.capitalized
        }
    }
}

extension SubmittedGoal {
    var presentationStatus: GoalPresentationStatus {
        GoalPresentationStatus(rawValue: status)
    }

    var displayGoal: String {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "Goal details unavailable") : trimmed
    }

    var turnProgress: Double? {
        guard let turnsUsed, let maxTurns, maxTurns > 0 else { return nil }
        return min(1, max(0, Double(turnsUsed) / Double(maxTurns)))
    }
}

struct GoalDecision: Decodable, Equatable {
    let status: String?
    let shouldContinue: Bool?
    let continuationPrompt: String?
    let verdict: String?
    let reason: String?
    let message: String?
    let messageKey: String?
    let messageArgs: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case status
        case shouldContinue
        case shouldContinueSnake = "should_continue"
        case continuationPrompt
        case continuationPromptSnake = "continuation_prompt"
        case verdict
        case reason
        case message
        case messageKey
        case messageKeySnake = "message_key"
        case messageArgs
        case messageArgsSnake = "message_args"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        shouldContinue = container.decodeLossyBoolIfPresent(forKey: .shouldContinue)
            ?? container.decodeLossyBoolIfPresent(forKey: .shouldContinueSnake)
        continuationPrompt = container.decodeLossyStringIfPresent(forKey: .continuationPrompt)
            ?? container.decodeLossyStringIfPresent(forKey: .continuationPromptSnake)
        verdict = container.decodeLossyStringIfPresent(forKey: .verdict)
        reason = container.decodeLossyStringIfPresent(forKey: .reason)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        messageKey = container.decodeLossyStringIfPresent(forKey: .messageKey)
            ?? container.decodeLossyStringIfPresent(forKey: .messageKeySnake)
        messageArgs = (try? container.decodeIfPresent([JSONValue].self, forKey: .messageArgs))
            ?? (try? container.decodeIfPresent([JSONValue].self, forKey: .messageArgsSnake))
    }
}
