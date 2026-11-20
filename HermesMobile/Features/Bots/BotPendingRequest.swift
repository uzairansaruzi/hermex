import Foundation

enum BotPendingRequest: Equatable {
    case approval(BotApprovalRequest)
    case question(BotQuestionRequest)
    case credential(BotCredentialRequest)
    case desktopTask(BotDesktopTaskRequest)
    case connection(BotConnectionOperation)

    var requestID: String {
        switch self {
        case .approval(let request): return request.requestID
        case .question(let request): return request.requestID
        case .credential(let request): return request.requestID
        case .desktopTask(let request): return request.requestID
        case .connection(let operation): return operation.opID
        }
    }
}

struct BotServerRequest: Equatable {
    let id: String
    let method: String
    let sessionID: String
    let pending: BotPendingRequest?
    let promptGeneration: Int?

    init?(_ frame: BotJSON) {
        guard let id = frame["id"].text, !id.isEmpty,
              let method = frame["method"].text, !method.isEmpty,
              var params = frame["params"].fields,
              let sessionID = params["session_id"]?.text, !sessionID.isEmpty else { return nil }
        self.id = id
        self.method = method
        self.sessionID = sessionID
        promptGeneration = params["execution_generation"]?.integer
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

struct BotApprovalRequest: Equatable {
    enum Choice: String, Equatable, CaseIterable {
        case once, session, always, deny
    }

    let requestID: String
    let command: String?
    let consequence: String?
    let workingDirectory: String?
    let choices: [Choice]
    let patternKeys: [String]
    let toolName: String?

    var scopeLine: AttributedString? {
        ApprovalScope.line(
            keys: patternKeys, description: consequence, command: command, toolName: toolName,
            host: .hermes(offersSession: choices.contains(.session), offersAlways: choices.contains(.always))
        )
    }

    init?(_ json: BotJSON) {
        guard let id = json["request_id"].text, !id.isEmpty else { return nil }
        requestID = id
        command = Self.trimmed(json["command"])
        consequence = Self.trimmed(json["description"])
        workingDirectory = Self.trimmed(json["cwd"])
        let keys = (json["pattern_keys"].list ?? []).compactMap { Self.trimmed($0) }
        patternKeys = keys.isEmpty ? Self.trimmed(json["pattern_key"]).map { [$0] } ?? [] : keys
        toolName = Self.trimmed(json["tool_name"])
        let present = json.fields?["choices"]
        if let present, present.list == nil {
            choices = [.deny]
        } else if let list = present?.list {
            let offered = list.compactMap { $0.text.flatMap(Choice.init(rawValue:)) }
            if offered.isEmpty { choices = [.deny] }
            else { choices = offered.contains(.deny) ? offered : offered + [.deny] }
        } else {
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

struct BotQuestionRequest: Equatable {
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
        let wireID: String?
        let prompt: String
        let choices: [Choice]
        let allowsMultipleChoices: Bool
        let lockedAnswer: String?

        var id: String { wireID ?? "" }
        var isAnswered: Bool { lockedAnswer != nil }
    }

    let requestID: String
    let questions: [Question]

    var isBatch: Bool { questions.first?.wireID != nil }
    var unansweredCount: Int { questions.filter { !$0.isAnswered }.count }

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

struct BotCredentialRequest: Equatable {
    enum Kind: String, Equatable, CaseIterable {
        case sudo, secret

        var skipConsequence: String {
            switch self {
            case .sudo: return String(localized: "Skip to let the command fail instead.")
            case .secret: return String(localized: "Skip to continue without it.")
            }
        }
    }

    let kind: Kind
    let requestID: String
    let envVar: String?
    let prompt: String?

    var title: String {
        switch kind {
        case .sudo: return String(localized: "Administrator password needed")
        case .secret: return String(localized: "Secret needed")
        }
    }

    var detail: String {
        switch kind {
        case .sudo:
            return String(localized: "A command on this Mac needs an administrator password to run.")
        case .secret:
            return prompt ?? String(localized: "This bot needs a secret value to carry on.")
        }
    }

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

struct BotDesktopTaskRequest: Equatable {
    enum Kind: String, Equatable, CaseIterable {
        case tour
        case terminalRead = "terminal.read"
        case windowRead = "window.read"
        case previewRead = "preview.read"
        case previewAct = "preview.act"

        func title(_ subject: HermesRequestSubject) -> String {
            switch (self, subject) {
            case (.terminalRead, .bot): return String(localized: "This bot is reading a terminal on the Mac.")
            case (.windowRead, .bot): return String(localized: "This bot is reading a window on the Mac.")
            case (.previewRead, .bot): return String(localized: "This bot is reading the preview pane on the Mac.")
            case (.previewAct, .bot): return String(localized: "This bot is using the preview pane on the Mac.")
            case (.tour, .bot): return String(localized: "This bot is running a tour in Hermes Desktop.")
            case (.terminalRead, .hermes): return String(localized: "Hermes is reading a terminal on the Mac.")
            case (.windowRead, .hermes): return String(localized: "Hermes is reading a window on the Mac.")
            case (.previewRead, .hermes): return String(localized: "Hermes is reading the preview pane on the Mac.")
            case (.previewAct, .hermes): return String(localized: "Hermes is using the preview pane on the Mac.")
            case (.tour, .hermes): return String(localized: "Hermes is running a tour in Hermes Desktop.")
            }
        }

        func detail(_ subject: HermesRequestSubject) -> String {
            switch subject {
            case .bot:
                return String(localized: "Hermes Desktop answers this by itself, and the bot carries on without it if it cannot. There is nothing to do here or at the Mac.")
            case .hermes:
                return String(localized: "Hermes Desktop answers this by itself, and Hermes carries on without it if it cannot. There is nothing to do here or at the Mac.")
            }
        }
    }

    let kind: Kind
    let requestID: String
}

struct BotConnectionOperation: Equatable {
    struct EnvField: Equatable, Identifiable {
        let name: String
        let isRequired: Bool
        let isSecret: Bool
        let defaultValue: String?
        let prompt: String?

        var id: String { name }

        func value(in values: [String: String]) -> String {
            values[name] ?? defaultValue ?? ""
        }

        init?(_ json: BotJSON) {
            guard let name = json["name"].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            self.name = name
            isRequired = json["required"].flag ?? true
            isSecret = json["secret"].flag ?? true
            defaultValue = isSecret ? nil : BotConnectionOperation.trimmed(json["default"])
            prompt = BotConnectionOperation.trimmed(json["prompt"])
        }
    }

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

        var canSkip: Bool {
            guard kind != nil, action != nil, let state else { return false }
            return [.pending, .initiated, .failed, .expired].contains(state)
        }

        var linkToOpen: URL? {
            guard kind == .connector, action != nil, state == .pending || state == .initiated,
                  let connectURL, connectURL.scheme?.lowercased() == "https" else { return nil }
            return connectURL
        }

        var finishesOnTheMac: Bool {
            guard kind == .mcp, action == .authorize || connectURL != nil, let state else { return false }
            return [.pending, .initiated, .failed].contains(state)
        }

        var canConnect: Bool {
            kind == .mcp && (action == .enable || action == .install) && connectURL == nil
                && (state == .pending || state == .failed)
        }

        func env(from values: [String: String]) -> [String: String] {
            requiredEnv.reduce(into: [:]) { env, field in
                let value = field.value(in: values).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { env[field.name] = value }
            }
        }

        func accepts(_ env: [String: String]) -> Bool {
            guard canConnect else { return false }
            let declared = Set(requiredEnv.map(\.name))
            return Set(env.keys).isSubset(of: declared) && !env.values.contains(where: \.isEmpty)
                && requiredEnv.allSatisfy { !$0.isRequired || env[$0.name] != nil }
        }
    }

    enum Answer: Equatable {
        case connect(target: String, env: [String: String])
        case skip(target: String)
        case continueWithout

        func isOffered(by operation: BotConnectionOperation) -> Bool {
            switch self {
            case .continueWithout: return true
            case .skip(let name): return operation.targets.first { $0.name == name }?.canSkip == true
            case .connect(let name, let env):
                return operation.targets.first { $0.name == name }?.accepts(env) == true
            }
        }

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
    let seq: Int
    let deadline: Date
    let isSettled: Bool
    let targets: [Target]

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

    func applying(_ frame: BotConnectionOperation) -> BotConnectionOperation {
        frame.opID == opID && frame.seq > seq ? frame : self
    }

    static func minutesLeft(until deadline: Date, now: Date) -> Int {
        max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
    }

    fileprivate static func trimmed(_ json: BotJSON) -> String? {
        let value = json.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

struct BotQuestionAnswer: Equatable {
    let questionID: String?
    let text: String

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

struct BotRequestResolution: Equatable {
    enum Outcome: Equatable {
        case answered
        case alreadyResolved
        case uncertain
    }

    let requestID: String
    let outcome: Outcome

    var blocksFurtherAnswers: Bool { outcome != .uncertain }

    func message(_ subject: HermesRequestSubject) -> String {
        switch (outcome, subject) {
        case (.answered, _): return String(localized: "Answer sent.")
        case (.alreadyResolved, _): return String(localized: "This request was already answered or has expired.")
        case (.uncertain, .bot): return String(localized: "Answer outcome unknown. Check this bot in Desktop before answering again.")
        case (.uncertain, .hermes): return String(localized: "Answer outcome unknown. Check Hermes Desktop before answering again.")
        }
    }
}

struct BotRequestWithdrawal: Equatable {
    struct Envelope: Equatable {
        let id: String
        let method: String
    }

    enum Family: Equatable {
        case approval, question
        case other

        init?(method: String) {
            switch method {
            case "approval": self = .approval
            case "clarify": self = .question
            case "tour", "terminal.read", "window.read", "preview.read", "preview.act": return nil
            default: self = .other
            }
        }
    }

    enum Reason: Equatable {
        case timeout
        case stopped
        case shutdown
        case other

        init?(_ wire: String?) {
            switch wire?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" {
            case "", "resolved": return nil
            case "timeout": self = .timeout
            case "interrupted", "session_closed": self = .stopped
            case "shutdown": self = .shutdown
            default: self = .other
            }
        }
    }

    let family: Family
    let reason: Reason

    init(family: Family, reason: Reason) {
        self.family = family
        self.reason = reason
    }

    init?(method: String, reason: String?) {
        guard let family = Family(method: method), let reason = Reason(reason) else { return nil }
        self.init(family: family, reason: reason)
    }

    var message: String {
        switch (family, reason) {
        case (.approval, .timeout): return String(localized: "Approval timed out, so it didn't run.")
        case (.approval, .stopped): return String(localized: "Approval withdrawn because the work stopped.")
        case (.approval, .shutdown): return String(localized: "Approval withdrawn because Hermes shut down.")
        case (.approval, .other): return String(localized: "Approval withdrawn.")
        case (.question, .timeout): return String(localized: "Question timed out. The bot carried on without an answer.")
        case (.question, .stopped): return String(localized: "Question withdrawn because the work stopped.")
        case (.question, .shutdown): return String(localized: "Question withdrawn because Hermes shut down.")
        case (.question, .other): return String(localized: "Question withdrawn.")
        case (.other, .timeout): return String(localized: "Request timed out. The bot carried on without it.")
        case (.other, .stopped): return String(localized: "Request withdrawn because the work stopped.")
        case (.other, .shutdown): return String(localized: "Request withdrawn because Hermes shut down.")
        case (.other, .other): return String(localized: "Request withdrawn.")
        }
    }

    var systemImage: String { reason == .timeout ? "clock" : "stop.circle" }
}
