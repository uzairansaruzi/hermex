import Foundation

/// A request that parks a bot's work until someone answers it.
///
/// Approvals and questions are read from the resume snapshot (`pending_approval`,
/// `pending_clarify`), so an answer given in Desktop clears them on the next read
/// and nothing has to poll. The Desktop-only kinds exist only as live gateway
/// events; the phone names them and never answers them.
enum BotPendingRequest: Equatable {
    case approval(BotApprovalRequest)
    case question(BotQuestionRequest)
    case desktopOnly(BotDesktopOnlyRequest)

    /// The host's id for this request. Nil only for a Desktop-only event that
    /// omitted one, which the phone never answers anyway.
    var requestID: String? {
        switch self {
        case .approval(let request): return request.requestID
        case .question(let request): return request.requestID
        case .desktopOnly(let request): return request.requestID
        }
    }

    /// False for the kinds the phone must send to Desktop instead of answering.
    var isAnswerable: Bool {
        if case .desktopOnly = self { return false }
        return true
    }
}

/// One pending dangerous-command approval. The host precomputes `choices` from
/// its own smart-approval and permanent-allow policy, so the phone offers exactly
/// what the host offered rather than inventing a fifth option.
struct BotApprovalRequest: Equatable {
    /// The host's wire vocabulary for `approval.respond`'s `choice`.
    enum Choice: String, Equatable, CaseIterable {
        case once, session, always, deny

        /// True for the choice that writes a permanent rule into the host's config.
        var isPermanent: Bool { self == .always }
    }

    let requestID: String
    /// The command as the host redacted it. Nil when the gate was not command-shaped.
    let command: String?
    /// Why the host flagged this action, from `description`.
    let consequence: String?
    /// Server order, `once` first and `deny` last. Never empty.
    let choices: [Choice]

    /// Nil when the payload carries no usable request id: without one the phone
    /// cannot address `approval.respond` and must not guess FIFO order.
    init?(_ json: BotJSON) {
        guard let id = json["request_id"].text, !id.isEmpty else { return nil }
        requestID = id
        command = Self.trimmed(json["command"])
        consequence = Self.trimmed(json["description"])
        let offered = (json["choices"].list ?? []).compactMap { $0.text.flatMap(Choice.init(rawValue:)) }
        // Older hosts may omit `choices`; rebuild the same set the gateway would.
        if offered.isEmpty {
            var rebuilt: [Choice] = [.once]
            if json["smart_denied"].flag != true, json["allow_session"].flag != false {
                rebuilt.append(.session)
                if json["allow_permanent"].flag != false { rebuilt.append(.always) }
            }
            choices = rebuilt + [.deny]
        } else {
            choices = offered.contains(.deny) ? offered : offered + [.deny]
        }
    }

    private static func trimmed(_ json: BotJSON) -> String? {
        let value = json.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// One pending clarify request: either the single-question shape
/// (`question`/`choices`/`multi_select`) or the batch shape (`questions`), which
/// locks one answer per question id and carries the locked ones back on reconnect.
struct BotQuestionRequest: Equatable {
    /// One offered answer. `wireLabel` goes back to the host verbatim; the host
    /// strips its own "(Recommended)" suffix, so presentation never leaks into
    /// the answer and the phone never has to reconstruct a label.
    struct Choice: Identifiable, Equatable {
        static let recommendedSuffix = "(Recommended)"

        let id: Int
        let wireLabel: String
        let label: String
        let isRecommended: Bool

        init(id: Int, wireLabel: String) {
            self.id = id
            self.wireLabel = wireLabel
            let trimmed = wireLabel.trimmingCharacters(in: .whitespaces)
            isRecommended = trimmed.lowercased().hasSuffix(Self.recommendedSuffix.lowercased())
            label = isRecommended
                ? String(trimmed.dropLast(Self.recommendedSuffix.count)).trimmingCharacters(in: .whitespaces)
                : trimmed
        }
    }

    struct Question: Identifiable, Equatable {
        /// The host's `qid`. Nil for the single-question shape, whose
        /// `clarify.respond` carries no `question_id`.
        let wireID: String?
        let prompt: String
        /// Empty means open-ended: free text is the only answer.
        let choices: [Choice]
        let allowsMultipleChoices: Bool
        /// An answer already locked on the host, replayed so a reconnect restores it.
        let lockedAnswer: String?

        var id: String { wireID ?? "" }
        var isAnswered: Bool { lockedAnswer != nil }
    }

    let requestID: String
    let questions: [Question]

    /// True when the host used the batch shape, which needs one `clarify.respond`
    /// per question id instead of a single unkeyed answer.
    var isBatch: Bool { questions.first?.wireID != nil }
    var unansweredCount: Int { questions.filter { !$0.isAnswered }.count }

    /// Nil when the payload has no request id or no readable question, which is
    /// how a host that carries the key but no content degrades to "no card".
    init?(_ json: BotJSON) {
        guard let id = json["request_id"].text, !id.isEmpty else { return nil }
        let locked = json["answers"]
        if let rows = json["questions"].list, !rows.isEmpty {
            let parsed: [Question] = rows.compactMap { row in
                guard let qid = row["qid"].text ?? row["id"].text, !qid.isEmpty,
                      let prompt = Self.trimmed(row["question"]) else { return nil }
                return Question(
                    wireID: qid, prompt: prompt, choices: Self.choices(row["choices"]),
                    allowsMultipleChoices: row["multi_select"].flag == true,
                    lockedAnswer: locked[qid].text
                )
            }
            guard !parsed.isEmpty else { return nil }
            requestID = id
            questions = parsed
            return
        }
        guard let prompt = Self.trimmed(json["question"]) else { return nil }
        requestID = id
        questions = [Question(
            wireID: nil, prompt: prompt, choices: Self.choices(json["choices"]),
            allowsMultipleChoices: json["multi_select"].flag == true, lockedAnswer: nil
        )]
    }

    private static func choices(_ json: BotJSON) -> [Choice] {
        (json.list ?? []).enumerated().compactMap { index, row in
            guard let label = trimmed(row) else { return nil }
            return Choice(id: index, wireLabel: label)
        }
    }

    private static func trimmed(_ json: BotJSON) -> String? {
        let value = json.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// A blocking request only Hermes Desktop can answer: it needs a credential, the
/// Mac's device context, or the Desktop renderer itself. The phone names the kind
/// so the block is legible, and offers no input, shell or credential fallback.
struct BotDesktopOnlyRequest: Equatable {
    /// The gateway event prefix, so `<raw>.request` and `<raw>.expire` both map here.
    enum Kind: String, Equatable, CaseIterable {
        case sudo, secret, tour
        case terminalRead = "terminal.read"
        case windowRead = "window.read"
        case mcpSetup = "mcp.setup"
        case previewRead = "preview.read"
        case previewAct = "preview.act"

        /// What the bot is asking for, in the user's words rather than the wire name.
        var title: String {
            switch self {
            case .sudo: return String(localized: "This bot is asking for an administrator password.")
            case .secret: return String(localized: "This bot is asking for a stored secret.")
            case .terminalRead: return String(localized: "This bot is asking to read a Desktop terminal.")
            case .windowRead: return String(localized: "This bot is asking to read a window on the Mac.")
            case .mcpSetup: return String(localized: "This bot is asking to finish an MCP setup.")
            case .previewRead: return String(localized: "This bot is asking to read the Desktop preview.")
            case .previewAct: return String(localized: "This bot is asking to act in the Desktop preview.")
            case .tour: return String(localized: "This bot is asking to run a Desktop tour.")
            }
        }
    }

    let kind: Kind
    let requestID: String?

    /// The kind a `<prefix>.request` event announces, or nil for any other event.
    static func requested(eventType: String, payload: BotJSON) -> BotDesktopOnlyRequest? {
        guard let kind = kind(eventType: eventType, suffix: "request") else { return nil }
        return BotDesktopOnlyRequest(kind: kind, requestID: payload["request_id"].text)
    }

    /// The kind a `<prefix>.expire` event tears down, or nil for any other event.
    static func expired(eventType: String) -> Kind? { kind(eventType: eventType, suffix: "expire") }

    private static func kind(eventType: String, suffix: String) -> Kind? {
        guard eventType.hasSuffix("." + suffix) else { return nil }
        return Kind(rawValue: String(eventType.dropLast(suffix.count + 1)))
    }
}

/// One question's answer on its way to `clarify.respond`. `questionID` is the
/// host's `qid` for a batch and nil for the single-question shape.
struct BotQuestionAnswer: Equatable {
    let questionID: String?
    let text: String

    /// Multi-select answers go over the wire as a JSON array string; the host
    /// parses that, a bare array is not part of the contract.
    init(questionID: String?, selections: [String]) {
        self.questionID = questionID
        let data = try? JSONSerialization.data(withJSONObject: selections)
        text = data.map { String(decoding: $0, as: UTF8.self) } ?? selections.joined(separator: ", ")
    }

    init(questionID: String?, text: String) {
        self.questionID = questionID
        self.text = text
    }
}

/// Why the request on screen can no longer be acted on, scoped to the request it
/// describes so a newer request never inherits an older verdict.
struct BotRequestResolution: Equatable {
    enum Outcome: Equatable {
        /// The host accepted the answer. The next snapshot removes the request.
        case answered
        /// The host had nothing left to resolve: answered on another surface, or expired.
        case alreadyResolved
        /// Delivery failed in a way that cannot distinguish sent from not sent.
        case uncertain
    }

    let requestID: String
    let outcome: Outcome

    /// True while the request must stay inert. An uncertain outcome warns instead
    /// of locking the user out: the phone never resends, but a deliberate second
    /// answer after checking Desktop is the user's call, not a replay.
    var blocksFurtherAnswers: Bool { outcome != .uncertain }

    var message: String {
        switch outcome {
        case .answered: return String(localized: "Answer sent.")
        case .alreadyResolved: return String(localized: "This request was already answered or has expired.")
        case .uncertain: return String(localized: "Answer outcome unknown. Check this bot in Desktop before answering again.")
        }
    }
}
