import Foundation

/// A request that parks a bot's work until someone answers it.
///
/// Requests arrive as server-request envelopes, live or restored from
/// `open_requests`; an approval can also come from the snapshot's
/// `pending_approval`. A connection operation is the one kind that is not a
/// server request: see `BotConnectionOperation`.
///
/// Only `desktopTask` is unanswerable, and not for want of a credential path: the
/// answer is data or input only Hermes Desktop holds, so no client without that
/// window can produce one.
enum BotPendingRequest: Equatable {
    case approval(BotApprovalRequest)
    case question(BotQuestionRequest)
    case credential(BotCredentialRequest)
    case desktopTask(BotDesktopTaskRequest)
    case connection(BotConnectionOperation)

    /// The host's id for this request: the envelope id, approval's queue id, or
    /// a connection operation's `op_id`.
    var requestID: String {
        switch self {
        case .approval(let request): return request.requestID
        case .question(let request): return request.requestID
        case .credential(let request): return request.requestID
        case .desktopTask(let request): return request.requestID
        case .connection(let operation): return operation.opID
        }
    }

    /// False only for the kinds whose answer lives in the Desktop renderer.
    var isAnswerable: Bool {
        if case .desktopTask = self { return false }
        return true
    }
}

/// A server request, received live or restored from `open_requests`.
/// Keep the envelope id separate from approval's underlying queue request id.
/// An unknown method keeps `pending` nil: the bot is still blocked, and the phone
/// never answers it, not even with -32601, because a reply from here would
/// pre-empt the Hermes Desktop window that can.
struct BotServerRequest: Equatable {
    let id: String
    let method: String
    let sessionID: String
    let pending: BotPendingRequest?

    init?(_ frame: BotJSON) {
        guard let id = frame["id"].text, !id.isEmpty,
              let method = frame["method"].text, !method.isEmpty,
              var params = frame["params"].fields,
              let sessionID = params["session_id"]?.text, !sessionID.isEmpty else { return nil }
        self.id = id
        self.method = method
        self.sessionID = sessionID
        if method == "approval" {
            pending = BotApprovalRequest(.object(params)).map(BotPendingRequest.approval)
        } else if method == "clarify" {
            params["request_id"] = .string(id)
            pending = BotQuestionRequest(.object(params)).map(BotPendingRequest.question)
        } else if let kind = BotCredentialRequest.Kind(rawValue: method) {
            pending = .credential(BotCredentialRequest(
                kind: kind, requestID: id,
                envVar: Self.trimmed(params["env_var"]), prompt: Self.trimmed(params["prompt"])
            ))
        } else if let kind = BotDesktopTaskRequest.Kind(rawValue: method) {
            pending = .desktopTask(BotDesktopTaskRequest(kind: kind, requestID: id))
        } else {
            pending = nil
        }
    }

    private static func trimmed(_ json: BotJSON?) -> String? {
        let value = json?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
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
        /// single answer carries no `question_id`.
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

    /// Batch questions lock one answer per question id (`clarify.lock` on 0.21.2).
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

/// A value only the person can supply: the Mac's administrator password, or a
/// secret the bot asked for by name.
///
/// Answers carry `{value}` through `request.answer`. An empty value skips
/// without retaining a secret.
struct BotCredentialRequest: Equatable {
    /// The server request method.
    enum Kind: String, Equatable, CaseIterable {
        case sudo, secret

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

/// A request only Hermes Desktop can answer. Most are work its own window
/// performs and answers by itself: serializing its terminal scrollback, the OS
/// window beneath it, its preview pane. Nobody types an answer to those, on the
/// phone or at the Mac; the host's deadline passes and the bot carries on, so the
/// phone reports the wait rather than sending anyone to a desk.
///
/// The password-manager prompts (`vault.*`) wait for a person at the Mac. The
/// phone cannot answer them, but it can skip one: an empty `value` is the host's
/// own "declined", so the bot moves on now instead of waiting for the Mac.
struct BotDesktopTaskRequest: Equatable {
    /// The server request method.
    enum Kind: String, Equatable, CaseIterable {
        case tour
        case terminalRead = "terminal.read"
        case windowRead = "window.read"
        case previewRead = "preview.read"
        case previewAct = "preview.act"
        case vaultUnlock = "vault.unlock_prompt"
        case vaultSaveLogin = "vault.save_login"
        case vaultCode = "vault.code"

        /// What is happening, in the user's words rather than the wire name.
        var title: String {
            switch self {
            case .terminalRead: return String(localized: "This bot is reading a terminal on the Mac.")
            case .windowRead: return String(localized: "This bot is reading a window on the Mac.")
            case .previewRead: return String(localized: "This bot is reading the preview pane on the Mac.")
            case .previewAct: return String(localized: "This bot is using the preview pane on the Mac.")
            case .tour: return String(localized: "This bot is running a tour in Hermes Desktop.")
            case .vaultUnlock: return String(localized: "This bot needs a password manager unlocked in Hermes Desktop.")
            case .vaultSaveLogin: return String(localized: "This bot wants to save a login in Hermes Desktop.")
            case .vaultCode: return String(localized: "This bot needs a sign-in code entered in Hermes Desktop.")
            }
        }

        /// True for the kinds a person answers at the Mac, which are also the
        /// kinds the phone can skip. Skipping is not answering: the password or
        /// code still only goes in at the Mac, but saying no is a decision the
        /// host takes from here. The rest have nothing to skip — the renderer
        /// answers or the deadline passes, and either way nobody is kept waiting.
        var needsSomeoneAtTheMac: Bool { [.vaultUnlock, .vaultSaveLogin, .vaultCode].contains(self) }

        var detail: String {
            needsSomeoneAtTheMac
                ? String(localized: "Answer this in Hermes Desktop on the Mac. Skip it here and the bot carries on without it.")
                : String(localized: "Hermes Desktop answers this by itself, and the bot carries on without it if it cannot. There is nothing to do here or at the Mac.")
        }
    }

    let kind: Kind
    let requestID: String
}

/// A `manage_connections` operation: the bot asked to connect one or more apps,
/// and the host holds the tool until every row is connected or skipped, Continue
/// settles it, Stop interrupts it, or its deadline passes.
///
/// It is an event plus an RPC, not a server request: `connection.request` opens
/// it, each `connection.update` carries the full snapshot again, the snapshot's
/// `pending_connection` restores it, and `connection.respond` answers it by
/// `op_id`. Nothing about it is cached.
struct BotConnectionOperation: Equatable {
    /// One value an MCP install still needs; the card draws a field for each.
    struct EnvField: Equatable, Identifiable {
        let name: String
        let isRequired: Bool
        let isSecret: Bool
        /// The catalog's value for a non-secret field, which applies when it is left empty.
        let defaultValue: String?
        let prompt: String?

        var id: String { name }

        init?(_ json: BotJSON) {
            guard let name = json["name"].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            self.name = name
            // Absent means the host's own defaults: required, and masked to be safe.
            isRequired = json["required"].flag ?? true
            isSecret = json["secret"].flag ?? true
            defaultValue = isSecret ? nil : BotConnectionOperation.trimmed(json["default"])
            prompt = BotConnectionOperation.trimmed(json["prompt"])
        }
    }

    /// One app the bot asked for. A value this build does not recognize keeps its
    /// row readable but offers nothing, since the phone cannot tell what it permits.
    struct Target: Equatable, Identifiable {
        enum Kind: String { case connector, mcp }
        enum Action: String { case authorize, connect, enable, install, reconnect }
        enum State: String {
            case pending, initiated, connected, skipped, failed, expired, unavailable
            case notConnected = "not_connected"
        }

        let name: String
        let kind: Kind?
        let action: Action?
        let state: State?
        let detail: String?
        let instructions: String?
        let discoveryError: String?
        let connectURL: URL?
        let requiredEnv: [EnvField]

        var id: String { name }

        init?(_ json: BotJSON) {
            guard let name = BotConnectionOperation.trimmed(json["name"]) else { return nil }
            self.name = name
            kind = json["kind"].text.flatMap(Kind.init(rawValue:))
            action = json["action"].text.flatMap(Action.init(rawValue:))
            state = json["state"].text.flatMap(State.init(rawValue:))
            detail = BotConnectionOperation.trimmed(json["detail"])
            instructions = BotConnectionOperation.trimmed(json["instructions"])
            discoveryError = BotConnectionOperation.trimmed(json["discovery_error"])
            connectURL = json["connect_url"].text.flatMap(URL.init(string:))
            requiredEnv = (json["required_env"].list ?? []).compactMap(EnvField.init)
        }

        /// The host lets the user skip any row still open: pending, started,
        /// failed or expired. Connected and skipped rows are already resolved.
        var canSkip: Bool {
            guard kind != nil, let state else { return false }
            return [.pending, .initiated, .failed, .expired].contains(state)
        }

        /// A managed connector's vendor sign-in. It finishes in the browser and the
        /// host notices the new account by itself, so the phone sends nothing back.
        /// Only an https link opens: a failed or expired row's link is dead.
        var linkToOpen: URL? {
            guard kind == .connector, state == .pending || state == .initiated,
                  let connectURL, connectURL.scheme?.lowercased() == "https" else { return nil }
            return connectURL
        }

        /// An MCP sign-in, which redirects to a listener on the host's own
        /// loopback. A phone browser dead-ends there, so it never gets the link.
        var finishesOnTheMac: Bool {
            guard kind == .mcp, action == .authorize || connectURL != nil, let state else { return false }
            return [.pending, .initiated, .failed].contains(state)
        }

        /// An MCP enable or install the phone approves, sending a value for each
        /// `requiredEnv` field. A failed one runs again with the new values.
        var canConnect: Bool {
            kind == .mcp && (action == .enable || action == .install) && connectURL == nil
                && (state == .pending || state == .failed)
        }

        /// True when this row connects with `env`: every required field filled,
        /// no field it did not declare, and no empty value.
        func accepts(_ env: [String: String]) -> Bool {
            guard canConnect else { return false }
            let declared = Set(requiredEnv.map(\.name))
            return Set(env.keys).isSubset(of: declared) && !env.values.contains(where: \.isEmpty)
                && requiredEnv.allSatisfy { !$0.isRequired || env[$0.name] != nil }
        }
    }

    /// One row's answer, or Continue, on its way to `connection.respond`.
    enum Answer: Equatable {
        case connect(target: String, env: [String: String])
        case skip(target: String)
        /// Settles the whole operation now; unresolved rows become `not_connected`.
        case continueWithout

        /// True when the row on screen offers this answer, with every required value filled.
        func isOffered(by operation: BotConnectionOperation) -> Bool {
            switch self {
            case .continueWithout: return true
            case .skip(let name): return operation.targets.first { $0.name == name }?.canSkip == true
            case .connect(let name, let env):
                return operation.targets.first { $0.name == name }?.accepts(env) == true
            }
        }

        /// The `result` object: one row per answer, or only `settled_by`.
        var result: BotJSON {
            switch self {
            case .connect(let name, let env):
                var row: [String: BotJSON] = ["name": .string(name), "status": .string("approved")]
                if !env.isEmpty { row["env"] = .object(env.mapValues(BotJSON.string)) }
                return .object(["targets": .array([.object(row)])])
            case .skip(let name):
                return .object(["targets": .array([.object(["name": .string(name), "status": .string("skipped")])])])
            case .continueWithout:
                return .object(["settled_by": .string("continue")])
            }
        }
    }

    let opID: String
    /// The host's write counter for this operation. A frame that is not newer is older.
    let seq: Int
    let deadline: Date
    let isSettled: Bool
    /// Server order, one row per name.
    let targets: [Target]

    /// Reads `connection.request`, a `connection.update` or `pending_connection`.
    /// Nil without an id, a counter, a deadline or any readable row: there is
    /// nothing a card could address, and the bot shows as blocked without one.
    init?(_ json: BotJSON) {
        guard let opID = json["op_id"].text, !opID.isEmpty, let seq = json["seq"].integer,
              let deadline = json["deadline_at"].number, deadline.isFinite, deadline > 0 else { return nil }
        var seen = Set<String>()
        let targets = (json["targets"].list ?? []).compactMap(Target.init).filter { seen.insert($0.name).inserted }
        guard !targets.isEmpty else { return nil }
        self.opID = opID
        self.seq = seq
        self.deadline = Date(timeIntervalSince1970: deadline)
        isSettled = json["settled"].flag == true
        self.targets = targets
    }

    /// This operation after `frame`: every frame is the full snapshot, so a newer
    /// one replaces it whole. An older or equal counter, or another operation's
    /// frame, changes nothing.
    func applying(_ frame: BotConnectionOperation) -> BotConnectionOperation {
        frame.opID == opID && frame.seq > seq ? frame : self
    }

    /// Whole minutes left before the host's deadline, never below one: the card
    /// stays until the settled frame, which the deadline itself produces.
    static func minutesLeft(until deadline: Date, now: Date) -> Int {
        max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
    }

    fileprivate static func trimmed(_ json: BotJSON) -> String? {
        let value = json.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// One question's answer on its way to the host. `questionID` is the
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
