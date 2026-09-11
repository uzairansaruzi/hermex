import Foundation

/// A request that parks a bot's work until someone answers it.
///
/// Approvals and questions are read from the resume snapshot (`pending_approval`,
/// `pending_clarify`), so an answer given in Desktop clears them on the next read
/// and nothing has to poll. Credential and Desktop-task requests exist only as
/// live gateway events, because the host's snapshot does not carry them.
///
/// Only `desktopTask` is unanswerable, and not for want of a credential path: the
/// answer is data Hermes Desktop's own window holds, so no client without that
/// window can produce one.
enum BotPendingRequest: Equatable {
    case approval(BotApprovalRequest)
    case question(BotQuestionRequest)
    case credential(BotCredentialRequest)
    case desktopTask(BotDesktopTaskRequest)

    /// The host's id for this request. Nil only for a Desktop-task event that
    /// omitted one, which nobody answers from here anyway.
    var requestID: String? {
        switch self {
        case .approval(let request): return request.requestID
        case .question(let request): return request.requestID
        case .credential(let request): return request.requestID
        case .desktopTask(let request): return request.requestID
        }
    }

    /// False only for the kinds whose answer lives in the Desktop renderer.
    var isAnswerable: Bool {
        if case .desktopTask = self { return false }
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
        // A present `choices` is the host speaking, and nothing may be added to
        // what it offered. If a newer host renames the lot so none of it parses,
        // Deny is the only thing left that is safe to offer: rebuilding here
        // would invent an Always allow the host never sanctioned.
        if let list = json["choices"].list {
            let offered = list.compactMap { $0.text.flatMap(Choice.init(rawValue:)) }
            if offered.isEmpty { choices = [.deny] }
            else { choices = offered.contains(.deny) ? offered : offered + [.deny] }
        } else {
            // Only an absent `choices` is an older host; rebuild what it would send.
            var rebuilt: [Choice] = [.once]
            if json["smart_denied"].flag != true, json["allow_session"].flag != false {
                rebuilt.append(.session)
                if json["allow_permanent"].flag != false { rebuilt.append(.always) }
            }
            choices = rebuilt + [.deny]
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

/// A blocking request the phone learns about only from the live event stream.
/// `session.resume` carries `pending_approval` and `pending_clarify` and nothing
/// else, so a gap in the stream loses these rather than leaving a stale card up.
enum BotStreamRequest: Equatable {
    case credential(BotCredentialRequest)
    case desktopTask(BotDesktopTaskRequest)

    var pending: BotPendingRequest {
        switch self {
        case .credential(let request): return .credential(request)
        case .desktopTask(let request): return .desktopTask(request)
        }
    }

    /// The gateway event prefix this was announced under, so the matching
    /// `<prefix>.expire` tears down this card and not a different one.
    var eventPrefix: String {
        switch self {
        case .credential(let request): return request.kind.rawValue
        case .desktopTask(let request): return request.kind.rawValue
        }
    }

    /// The request a `<prefix>.request` event announces, or nil for any other event.
    static func requested(eventType: String, payload: BotJSON) -> BotStreamRequest? {
        guard let prefix = prefix(eventType: eventType, suffix: "request") else { return nil }
        if let kind = BotCredentialRequest.Kind(rawValue: prefix) {
            // Without a request id there is nothing to address `*.respond` to, and
            // guessing one would answer somebody else's prompt.
            guard let id = payload["request_id"].text, !id.isEmpty else { return nil }
            return .credential(BotCredentialRequest(
                kind: kind, requestID: id,
                envVar: trimmed(payload["env_var"]), prompt: trimmed(payload["prompt"])
            ))
        }
        guard let kind = BotDesktopTaskRequest.Kind(rawValue: prefix) else { return nil }
        return .desktopTask(BotDesktopTaskRequest(kind: kind, requestID: payload["request_id"].text))
    }

    /// The event prefix a `<prefix>.expire` event tears down, or nil for any other event.
    static func expiredPrefix(eventType: String) -> String? { prefix(eventType: eventType, suffix: "expire") }

    private static func prefix(eventType: String, suffix: String) -> String? {
        guard eventType.hasSuffix("." + suffix) else { return nil }
        return String(eventType.dropLast(suffix.count + 1))
    }

    private static func trimmed(_ json: BotJSON) -> String? {
        let value = json.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// A value only the person can supply: the Mac's administrator password, or a
/// secret the bot asked for by name.
///
/// The phone answers these. `sudo.respond` and `secret.respond` take a
/// `request_id` from any connected client — the host's own terminal UI answers
/// them over the same methods — so routing them to Desktop was a choice, not a
/// constraint, and it is the wrong one for someone away from their Mac. An empty
/// value is the host's documented skip and releases the bot without one.
struct BotCredentialRequest: Equatable {
    /// The gateway event prefix, which is also the `*.respond` method's stem.
    enum Kind: String, Equatable, CaseIterable {
        case sudo, secret

        var respondMethod: String { "\(rawValue).respond" }

        /// The param `*.respond` carries the typed value in. The host reads one
        /// name per kind; a mismatched key answers with an empty string.
        var valueKey: String {
            switch self {
            case .sudo: return "password"
            case .secret: return "value"
            }
        }

        var title: String {
            switch self {
            case .sudo: return String(localized: "Administrator password needed")
            case .secret: return String(localized: "Secret needed")
            }
        }

        /// What skipping costs, so declining is an informed choice too.
        var skipConsequence: String {
            switch self {
            case .sudo: return String(localized: "Skip to let the command fail instead.")
            case .secret: return String(localized: "Skip to continue without it.")
            }
        }
    }

    let kind: Kind
    let requestID: String
    /// `secret` only: the name the host stores the value under.
    let envVar: String?
    /// `secret` only: the host's own words for what it wants.
    let prompt: String?

    /// What the bot is asking for, preferring the host's wording when it sent any.
    var detail: String {
        switch kind {
        case .sudo:
            return String(localized: "A command on this Mac needs an administrator password to run.")
        case .secret:
            return prompt ?? String(localized: "This bot needs a secret value to carry on.")
        }
    }

    /// Where the value ends up, stated before it is typed. `sudo` is used for the
    /// one command and never written down; `secret` is saved on the host under
    /// `envVar`. Neither is ever stored by Hermex.
    var handling: String {
        switch kind {
        case .sudo:
            return String(localized: "Sent to this bot's Mac to run this command. Hermex never saves it.")
        case .secret:
            guard let envVar else {
                return String(localized: "Saved on this bot's Mac. Hermex never saves it.")
            }
            return String(localized: "Saved on this bot's Mac as \(envVar). Hermex never saves it.")
        }
    }
}

/// Work Hermes Desktop's own window performs and answers by itself: serializing
/// its terminal scrollback, the OS window beneath it, its preview pane.
///
/// Nobody types an answer to these, on the phone or at the Mac. Each carries a
/// host-side deadline — 30s for the reads, 45s for the preview and tour, ten
/// minutes for an MCP setup — after which the tool takes an empty answer and the
/// bot carries on. So the phone reports the wait rather than sending anyone to a
/// desk they are not sitting at.
struct BotDesktopTaskRequest: Equatable {
    /// The gateway event prefix, so `<raw>.request` and `<raw>.expire` both map here.
    enum Kind: String, Equatable, CaseIterable {
        case tour
        case terminalRead = "terminal.read"
        case windowRead = "window.read"
        case mcpSetup = "mcp.setup"
        case previewRead = "preview.read"
        case previewAct = "preview.act"

        /// What is happening, in the user's words rather than the wire name.
        var title: String {
            switch self {
            case .terminalRead: return String(localized: "This bot is reading a terminal on the Mac.")
            case .windowRead: return String(localized: "This bot is reading a window on the Mac.")
            case .previewRead: return String(localized: "This bot is reading the preview pane on the Mac.")
            case .previewAct: return String(localized: "This bot is using the preview pane on the Mac.")
            case .tour: return String(localized: "This bot is running a tour in Hermes Desktop.")
            case .mcpSetup: return String(localized: "This bot is waiting for an MCP server to be set up in Hermes Desktop.")
            }
        }

        /// True for the one kind a person actually walks through at the Mac.
        var needsSomeoneAtTheMac: Bool { self == .mcpSetup }

        /// True for the kind the phone can call off outright. Declining is not
        /// answering: the setup card's work still only happens in Desktop, but
        /// saying no to it is a decision, and the host takes that from here.
        /// The rest have nothing to decline — the renderer answers or the
        /// deadline passes, and either way nobody is kept waiting.
        var isDeclinable: Bool { self == .mcpSetup }

        var respondMethod: String { "\(rawValue).respond" }

        var detail: String {
            needsSomeoneAtTheMac
                ? String(localized: "Hermes Desktop walks someone through this on the Mac. Skip it here and the bot carries on without the server.")
                : String(localized: "Hermes Desktop answers this by itself, and the bot carries on without it if it cannot. There is nothing to do here or at the Mac.")
        }
    }

    /// The `result` an explicit decline carries. The host passes the object
    /// straight through to the tool, which reads `declined` as a final no and
    /// is told never to re-ask — unlike an unanswered card, which only means
    /// the ten-minute deadline passed.
    static let declinedResult = #"{"status":"declined"}"#

    let kind: Kind
    let requestID: String?
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
