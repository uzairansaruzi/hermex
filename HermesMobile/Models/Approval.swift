import Foundation

enum ApprovalChoice: String, Codable, CaseIterable, Equatable {
    case once
    case session
    case always
    case deny
}

struct ApprovalPendingResponse: Decodable, Equatable {
    let pending: PendingApproval?
    let pendingCount: Int?

    init(pending: PendingApproval?, pendingCount: Int?) {
        self.pending = pending
        self.pendingCount = pendingCount
    }

    enum CodingKeys: String, CodingKey {
        case pending
        case pendingCount
        case pendingCountSnake = "pending_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = try? container.decodeIfPresent(PendingApproval.self, forKey: .pending)
        pendingCount = container.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? container.decodeLossyIntIfPresent(forKey: .pendingCountSnake)
    }

    static func streamPayload(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> ApprovalPendingResponse {
        if let wrapped = try? decoder.decode(Self.self, from: data),
           wrapped.pending != nil || wrapped.pendingCount != nil {
            return wrapped
        }

        if let direct = try? decoder.decode(PendingApproval.self, from: data),
           !direct.isEmpty {
            return ApprovalPendingResponse(pending: direct, pendingCount: 1)
        }

        return ApprovalPendingResponse(pending: nil, pendingCount: nil)
    }
}

struct PendingApproval: Decodable, Equatable, Identifiable {
    var id: String {
        if let approvalId, !approvalId.isEmpty {
            return approvalId
        }

        return "\(command ?? "")-\(description ?? "")-\(displayPatternKeys.joined(separator: ","))"
    }

    let approvalId: String?
    let command: String?
    let description: String?
    let patternKey: String?
    let patternKeys: [String]?

    var displayPatternKeys: [String] {
        let keys = patternKeys?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !keys.isEmpty {
            return keys
        }

        guard let patternKey = patternKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !patternKey.isEmpty
        else {
            return []
        }

        return [patternKey]
    }

    var isEmpty: Bool {
        approvalId == nil
            && command == nil
            && description == nil
            && patternKey == nil
            && (patternKeys?.isEmpty ?? true)
    }

    init(
        approvalId: String? = nil,
        command: String? = nil,
        description: String? = nil,
        patternKey: String? = nil,
        patternKeys: [String]? = nil
    ) {
        self.approvalId = Self.normalizedApprovalId(approvalId)
        self.command = command
        self.description = description
        self.patternKey = patternKey
        self.patternKeys = patternKeys
    }

    enum CodingKeys: String, CodingKey {
        case id
        case approvalId
        case approvalIdSnake = "approval_id"
        case command
        case description
        case patternKey
        case patternKeySnake = "pattern_key"
        case patternKeys
        case patternKeysSnake = "pattern_keys"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = Self.decodeApprovalId(from: container)
        command = container.decodeLossyStringIfPresent(forKey: .command)
        description = container.decodeLossyStringIfPresent(forKey: .description)
        patternKey = container.decodeLossyStringIfPresent(forKey: .patternKey)
            ?? container.decodeLossyStringIfPresent(forKey: .patternKeySnake)
        patternKeys = Self.decodeStringArray(from: container, keys: [.patternKeys, .patternKeysSnake])
    }

    private static func decodeStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> [String]? {
        for key in keys {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                return values
            }

            if let values = try? container.decodeIfPresent([JSONValue].self, forKey: key) {
                return values.compactMap(\.lossyString)
            }

            if let value = container.decodeLossyStringIfPresent(forKey: key) {
                return [value]
            }
        }

        return nil
    }

    private static func decodeApprovalId(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        for key in [CodingKeys.approvalId, .approvalIdSnake, .id] {
            if let value = normalizedApprovalId(container.decodeLossyStringIfPresent(forKey: key)) {
                return value
            }
        }

        return nil
    }

    private static func normalizedApprovalId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// The one line an approval card shows above its buttons, saying what Allow
/// session and Always allow will cover. Bot Chat and the Sessions overlay both
/// build it from the request on screen.
///
/// A raw pattern key never reaches the screen. A shell key is the host's own
/// danger description (`detect_dangerous_command` returns it as the key), so it
/// is quoted as sent; the other shapes hermes-agent `ca678285` writes get a
/// plain label, and anything else is "every action like this one". Each case is
/// one whole-sentence catalog string, so only host text is interpolated, and a
/// tool or action identifier is marked as code so it renders monospaced.
enum ApprovalScope {
    /// Whose allowlist the choices write, which fixes the nouns and whether
    /// Always keeps a security finding session-only.
    enum Host: Equatable {
        /// Bot Chat on Hermes. Session means this chat; Always writes the
        /// Profile's `command_allowlist` and downgrades Tirith findings to the
        /// session. Only the choices the host offered are described.
        case hermes(offersSession: Bool, offersAlways: Bool)
        /// The Sessions overlay on webui, which always offers both. Always
        /// writes the server's allowlist, Tirith findings included.
        case webui
    }

    /// What one set of keys allowlists, in the terms the line can name.
    private enum Subject: Equatable {
        case shell(String)
        case pluginTool(String)
        case pythonScript
        case sshConfig
        case computerUse(action: String, mode: String)
        case securityFinding
        case shellAndSecurityFinding(String)
        case other
    }

    /// Keys whose prompts grant every allow choice for one call only and save
    /// nothing: MCP trust and elicitation consent (`_consent` in
    /// `tools/approval_prompt.py`) and protected instruction file writes
    /// (`tools/file_tools_write_guards.py`).
    private static let oneTimeKeys: Set<String> = ["mcp_elicitation", "protected_instruction_file"]

    /// Nil when Allow session isn't offered (a smart-denied prompt, or a room
    /// approval's once and deny), the host sent no keys to allowlist, or the
    /// prompt is a one-time confirmation with no scope to describe.
    static func line(
        keys: [String], description: String?, command: String?, toolName: String?, host: Host
    ) -> AttributedString? {
        guard !keys.isEmpty, !keys.contains(where: oneTimeKeys.contains) else { return nil }
        let subject = subject(of: keys, description: description, command: command, toolName: toolName)
        switch host {
        case .webui:
            return serverSentence(subject)
        case .hermes(let offersSession, let offersAlways):
            guard offersSession else { return nil }
            return offersAlways ? profileSentence(subject) : chatSentence(subject)
        }
    }

    /// A command prompt carries at most one Tirith finding and one shell key
    /// (`check_all_command_guards`); every other gate sends a single key.
    private static func subject(
        of keys: [String], description: String?, command: String?, toolName: String?
    ) -> Subject {
        let findings = keys.filter { $0.hasPrefix("tirith:") }
        let others = keys.filter { !$0.hasPrefix("tirith:") }
        switch (findings.count, others.count) {
        case (1, 0):
            return .securityFinding
        case (0, 1):
            return subject(of: others[0], description: description, command: command, toolName: toolName)
        case (1, 1):
            if case .shell(let label) = subject(of: others[0], description: description, command: nil, toolName: nil) {
                return .shellAndSecurityFinding(label)
            }
            return .other
        default:
            return .other
        }
    }

    private static func subject(of key: String, description: String?, command: String?, toolName: String?) -> Subject {
        if key == "execute_code" { return .pythonScript }
        if key == "ssh_config_write" { return .sshConfig }
        if key.hasPrefix("plugin_rule:") {
            let rule = key.dropFirst("plugin_rule:".count)
            return pluginTool(rule: rule, command: command, toolName: toolName).map(Subject.pluginTool) ?? .other
        }
        if let match = key.wholeMatch(of: /cua:([^:]+):([^:]+)/) {
            return .computerUse(action: String(match.1), mode: String(match.2))
        }
        // A shell key is one `; `-joined part of the description. Checked last:
        // the `execute_code` description also mentions its key.
        let parts = description?.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts?.contains(key) == true ? .shell(key) : .other
    }

    /// The tool from the default `<tool>:<sha12>` rule key, else the host's
    /// `tool_name`, else the `<tool>` the command shows. A custom rule key
    /// names no tool, and the rule key itself is never a label.
    private static func pluginTool(rule: Substring, command: String?, toolName: String?) -> String? {
        if let match = rule.wholeMatch(of: /(.+):[0-9a-f]{12}/) { return String(match.1) }
        if let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty {
            return toolName
        }
        return command.flatMap { $0.prefixMatch(of: /<([^<>\s]+)>/) }.map { String($0.1) }
    }

    /// Hermes with both choices offered.
    private static func profileSentence(_ subject: Subject) -> AttributedString {
        switch subject {
        case .shell(let label):
            return AttributedString(localized: "Allow session covers every “\(label)” in this chat; Always allow covers it for this Profile from now on.")
        case .pluginTool(let tool):
            return AttributedString(localized: "Allow session covers every \(code(tool)) call for this reason in this chat; Always allow covers it for this Profile from now on.")
        case .pythonScript:
            return AttributedString(localized: "Allow session covers every Python script in this chat; Always allow covers every Python script for this Profile from now on.")
        case .sshConfig:
            return AttributedString(localized: "Allow session covers writes to SSH config in this chat; Always allow covers them for this Profile from now on.")
        case .computerUse(let action, let mode):
            return AttributedString(localized: "Allow session covers computer use: \(code(action)) (\(mode)) in this chat; Always allow covers it for this Profile from now on.")
        case .shellAndSecurityFinding(let label):
            return AttributedString(localized: "Allow session covers “\(label)” and this security finding in this chat; Always allow covers “\(label)” for this Profile from now on. The security finding stays allowed for this chat only.")
        case .securityFinding:
            // Hermes keeps a finding session-only under Always too.
            return chatSentence(subject)
        case .other:
            return AttributedString(localized: "Allow session covers every action like this one in this chat; Always allow covers it for this Profile from now on.")
        }
    }

    /// Hermes with Allow session but no Always: at the pin, only a prompt whose
    /// keys are all Tirith findings (`permanent_capable` is false).
    private static func chatSentence(_ subject: Subject) -> AttributedString {
        if subject == .securityFinding {
            return AttributedString(localized: "Allow session covers this security finding in this chat.")
        }
        return AttributedString(localized: "Allow session covers every action like this one in this chat.")
    }

    /// webui, where both choices are always offered and Always persists every key.
    private static func serverSentence(_ subject: Subject) -> AttributedString {
        switch subject {
        case .shell(let label):
            return AttributedString(localized: "Allow session covers every “\(label)” in this session; Always allow covers it on this server from now on.")
        case .pluginTool(let tool):
            return AttributedString(localized: "Allow session covers every \(code(tool)) call for this reason in this session; Always allow covers it on this server from now on.")
        case .pythonScript:
            return AttributedString(localized: "Allow session covers every Python script in this session; Always allow covers every Python script on this server from now on.")
        case .sshConfig:
            return AttributedString(localized: "Allow session covers writes to SSH config in this session; Always allow covers them on this server from now on.")
        case .computerUse(let action, let mode):
            return AttributedString(localized: "Allow session covers computer use: \(code(action)) (\(mode)) in this session; Always allow covers it on this server from now on.")
        case .securityFinding:
            return AttributedString(localized: "Allow session covers this security finding in this session; Always allow covers it on this server from now on.")
        case .shellAndSecurityFinding(let label):
            return AttributedString(localized: "Allow session covers “\(label)” and this security finding in this session; Always allow covers both on this server from now on.")
        case .other:
            return AttributedString(localized: "Allow session covers every action like this one in this session; Always allow covers it on this server from now on.")
        }
    }

    /// A host identifier, shown raw and monospaced.
    private static func code(_ identifier: String) -> AttributedString {
        var text = AttributedString(identifier)
        text.inlinePresentationIntent = .code
        return text
    }
}

struct ApprovalRespondResponse: Decodable, Equatable {
    let ok: Bool?
    let choice: ApprovalChoice?
    /// Server cleared a stale card whose approval already resolved (benign 200; issue #25).
    let staleCleared: Bool?
    /// The respond was relayed to a gateway-managed run rather than resolved locally.
    let relayed: Bool?
    /// The prompt already expired (paired with a 409 on the docs' respond contract).
    let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case choice
        case staleCleared
        case staleClearedSnake = "stale_cleared"
        case relayed
        case stale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        choice = try? container.decodeIfPresent(ApprovalChoice.self, forKey: .choice)
        staleCleared = container.decodeLossyBoolIfPresent(forKey: .staleCleared)
            ?? container.decodeLossyBoolIfPresent(forKey: .staleClearedSnake)
        relayed = container.decodeLossyBoolIfPresent(forKey: .relayed)
        stale = container.decodeLossyBoolIfPresent(forKey: .stale)
    }
}

struct SessionYoloResponse: Decodable, Equatable {
    let ok: Bool?
    let yoloEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case yoloEnabled
        case yoloEnabledSnake = "yolo_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        yoloEnabled = container.decodeLossyBoolIfPresent(forKey: .yoloEnabled)
            ?? container.decodeLossyBoolIfPresent(forKey: .yoloEnabledSnake)
    }
}

private extension JSONValue {
    var lossyString: String? {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            "\(value)"
        case .bool(let value):
            value ? "true" : "false"
        case .object, .array, .null:
            nil
        }
    }
}
