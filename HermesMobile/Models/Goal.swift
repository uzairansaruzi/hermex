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

    /// A goal read from somewhere other than the webui, such as a Hermes session's
    /// `session.control` snapshot (#1013).
    init(goal: String?, status: String?, turnsUsed: Int?, maxTurns: Int?, lastVerdict: String?,
         lastReason: String?, pausedReason: String?) {
        self.goal = goal
        self.status = status
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
        self.lastVerdict = lastVerdict
        self.lastReason = lastReason
        self.pausedReason = pausedReason
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
