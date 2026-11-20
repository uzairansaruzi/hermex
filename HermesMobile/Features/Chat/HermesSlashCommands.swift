import Foundation
import Observation

struct HermesSlashCatalog: Equatable {
    private(set) var commands: [AgentCommand] = []
    private(set) var canonical: [String: String] = [:]
    private(set) var skills: [SkillSlashSuggestion] = []
    private(set) var hostArgumentNames: Set<String> = []

    init() {}

    init(_ reply: BotJSON) {
        skills = BotSlashCatalog.skills(from: reply)
        var aliases: [String: [String]] = [:]
        for (key, target) in reply["canon"].fields ?? [:] {
            guard let alias = Self.name(key), let name = Self.name(target.text) else { continue }
            canonical[alias.lowercased()] = name
            if alias.lowercased() != name.lowercased() { aliases[name.lowercased(), default: []].append(alias) }
        }
        hostArgumentNames = Set(canonical.compactMap { alias, name in
            [alias, name.lowercased()].contains { SlashCommandCatalog.hermesCommand(named: $0) != nil } ? nil : alias
        })
        var seen = Set<String>()
        for row in reply["pairs"].list ?? [] {
            guard let cells = row.list, let name = Self.name(cells.first?.text),
                  canonical[name.lowercased()]?.lowercased() == name.lowercased(),
                  seen.insert(name.lowercased()).inserted else { continue }
            commands.append(AgentCommand(name: name, description: cells.dropFirst().first?.text,
                                         aliases: aliases[name.lowercased()]?.sorted()))
        }
    }

    func command(named name: String) -> String? { canonical[name.lowercased()] }

    private static func name(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), key.hasPrefix("/") else { return nil }
        let name = String(key.dropFirst())
        guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return name
    }
}

enum HermesChatPolicy: Equatable {
    case session
    case botChat

    init(target: ConversationTarget, botChatRoot: String? = nil) {
        if case .canonicalChat = target { self = .botChat } else { self = botChatRoot == nil ? .session : .botChat }
    }

    func refusal(typed name: String, canonical: String) -> String? {
        guard self == .botChat else { return nil }
        switch canonical.lowercased() {
        case "new", "reset":
            return String(localized: "A bot keeps one chat, so /\(name) can’t start another.")
        case "clear":
            return String(localized: "A bot keeps one chat, so /\(name) can’t start another. Run /compress to free up its context.")
        case "resume", "sessions":
            return String(localized: "A bot keeps one chat, so /\(name) can’t open another.")
        case "branch", "fork":
            return String(localized: "A bot’s chat can’t be forked.")
        case "title":
            return String(localized: "A bot’s chat keeps the bot’s name.")
        case "undo", "retry":
            return String(localized: "A bot’s chat can’t be rewound.")
        default:
            return nil
        }
    }

    var offersHistoryActions: Bool { self == .session }
    var picksProfile: Bool { self == .session }
    var offersMentions: Bool { self == .botChat }
}

enum HermesSlashRoute: Equatable {
    case refused(String)
    case appOwned(SlashCommand)
    case skill(SkillSlashSuggestion)
    case host
    case text
}

enum HermesSlashReply: Equatable {
    case notice(String)
    case send(message: String, shown: String, notice: String?)
    case prefill(message: String, notice: String?)
    case alias(target: String)

    init?(_ reply: BotJSON, typed: String) {
        let notice = Self.nonEmpty(reply["notice"].text)
        let message = Self.nonEmpty(reply["message"].text)
        switch reply["type"].text {
        case nil, "exec", "plugin":
            let output = reply["output"].text ?? ""
            var parts = [Self.verbatim(output)]
            if let warning = Self.nonEmpty(reply["warning"].text) { parts.insert(warning, at: 0) }
            if let notice { parts.insert(notice, at: 0) }
            self = .notice(parts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        case "send", "skill":
            guard let message else { return nil }
            let shown = Self.nonEmpty(reply["display"].text) ?? (reply["type"].text == "skill" ? typed : message)
            self = .send(message: message, shown: shown, notice: notice)
        case "prefill":
            guard let message else { return nil }
            self = .prefill(message: message, notice: notice)
        case "alias":
            guard let target = Self.nonEmpty(reply["target"].text)?.trimmingCharacters(in: .whitespaces) else { return nil }
            self = .alias(target: target.hasPrefix("/") ? String(target.dropFirst()) : target)
        default:
            return nil
        }
    }

    static func verbatim(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        var fence = "```"
        while trimmed.contains(fence) { fence += "`" }
        return "\(fence)text\n\(trimmed)\n\(fence)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

struct HermesCheckpoint: Equatable {
    let number: Int
    let hash: String
    let timestamp: String
    let message: String

    var shortHash: String { String(hash.prefix(8)) }

    static func list(_ reply: BotJSON) -> [HermesCheckpoint]? {
        guard reply["enabled"].flag != false else { return nil }
        let rows = (reply["checkpoints"].list ?? []).compactMap { row -> (hash: String, row: BotJSON)? in
            guard let hash = row["hash"].text, !hash.isEmpty else { return nil }
            return (hash, row)
        }
        return rows.enumerated().map { index, entry in
            HermesCheckpoint(number: index + 1, hash: entry.hash, timestamp: entry.row["timestamp"].text ?? "",
                             message: entry.row["message"].text ?? "")
        }
    }

    static func named(_ ref: String, in list: [HermesCheckpoint]) -> HermesCheckpoint? {
        if !ref.isEmpty, ref.allSatisfy({ $0.isASCII && $0.isNumber }), !ref.hasPrefix("0"), let number = Int(ref), list.indices.contains(number - 1) {
            return list[number - 1]
        }
        guard ref.count >= 4 else { return nil }
        let matches = list.filter { $0.hash.lowercased().hasPrefix(ref.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum HermesRollbackCommand: Equatable {
    case list
    case diff(String)
    case restore(String, filePath: String?)

    init?(_ argument: String) {
        let words = argument.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.contains("--all") else { return nil }
        switch words.first?.lowercased() {
        case nil, "list", "ls":
            guard words.count <= 1 else { return nil }
            self = .list
        case "diff":
            guard words.count == 2 else { return nil }
            self = .diff(words[1])
        default:
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = text.drop { !$0.isWhitespace }.drop { $0.isWhitespace }
            self = .restore(words[0], filePath: rest.isEmpty ? nil : String(rest))
        }
    }
}

struct HermesRollbackRequest: Equatable {
    let checkpoint: HermesCheckpoint
    let filePath: String?
}

struct HermesRollbackOutcome: Equatable {
    let success: Bool
    let error: String?
    let restoredFiles: [String]
    let skippedUserEdits: [String]
    let historyRemoved: Int

    init(_ reply: BotJSON) {
        success = reply["success"].flag == true
        error = reply["error"].text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        restoredFiles = (reply["restored_files"].list ?? []).compactMap(\.text)
        skippedUserEdits = (reply["skipped_user_edits"].list ?? []).compactMap(\.text)
        historyRemoved = reply["history_removed"].integer ?? 0
    }
}

struct HermesSlashCompletion: Equatable {
    struct Item: Equatable, Identifiable {
        let text: String
        let display: String
        let meta: String
        var id: String { text }
    }

    let text: String
    let items: [Item]
    let replaceFrom: Int

    private var head: String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, replaceFrom))))
    }

    func applies(to current: String) -> Bool {
        current.hasPrefix(head) && !current.unicodeScalars.dropFirst(head.unicodeScalars.count)
            .contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    func applying(_ item: Item) -> String { head + item.text }
}

@MainActor @Observable final class HermesSlashCommands {
    private(set) var catalog = HermesSlashCatalog() {
        didSet {
            scope.hostCommands = catalog.hostArgumentNames
            if catalog.skills != oldValue.skills { onSkills(catalog.skills) }
        }
    }
    private(set) var scope: SlashCommandScope
    var commands: [AgentCommand] {
        guard policy == .botChat else { return catalog.commands }
        return catalog.commands.filter { command in
            command.name.map { policy.refusal(typed: $0, canonical: $0) == nil } ?? true
        }
    }
    private(set) var completion: HermesSlashCompletion?
    @ObservationIgnored var completionDelay: Duration = .milliseconds(150)
    @ObservationIgnored private var completionRevision = 0
    @ObservationIgnored var onNeedsReattach: () -> Void = {}
    @ObservationIgnored var onSkills: ([SkillSlashSuggestion]) -> Void = { _ in }
    let policy: HermesChatPolicy
    private let engine: HermesConversation

    init(engine: HermesConversation, policy: HermesChatPolicy = .session) {
        self.engine = engine
        self.policy = policy
        scope = SlashCommandScope(builtins: SlashCommandCatalog.hermesCommands.filter {
            policy.refusal(typed: $0.name, canonical: $0.name) == nil
        }, isHermes: true)
    }

    func connect(runtime: String, attempt: Int) async {
        guard engine.generation == attempt, engine.connectionState == .connected,
              let reply = try? await engine.request(.commandsCatalog(sessionID: runtime), attempt: attempt)
        else { return }
        catalog = HermesSlashCatalog(reply)
    }

    func route(_ name: String) -> HermesSlashRoute {
        let typed = name.lowercased()
        let canonical = catalog.command(named: typed)?.lowercased() ?? typed
        if let refusal = policy.refusal(typed: name, canonical: canonical) { return .refused(refusal) }
        if let command = SlashCommandCatalog.hermesCommand(named: typed) ?? SlashCommandCatalog.hermesCommand(named: canonical) {
            return .appOwned(command)
        }
        if let skill = SlashSkillFormatter.skill(named: name, in: catalog.skills) { return .skill(skill) }
        return catalog.command(named: typed) == nil ? .text : .host
    }

    func run(_ line: String) async throws -> HermesSlashReply {
        let reply = try await write { .slashExec(sessionID: $0, command: line) }
        guard let parsed = HermesSlashReply(reply, typed: line) else { throw BotFailure.unsupported }
        return parsed
    }

    func rename(_ title: String) async throws -> String {
        let reply = engine.wire.speaksCanonicalProtocol
            ? try await mutate(.rename(title))
            : try await write { .sessionRename(runtime: $0, title: title) }
        return reply["title"].text.flatMap { $0.isEmpty ? nil : $0 } ?? title
    }

    func expand(_ skill: SkillSlashSuggestion, argument: String, typed: String) async throws -> HermesSlashReply {
        let reply = try await write { .commandDispatch(name: skill.name, argument: argument, sessionID: $0) }
        guard reply["type"].text == "skill", let parsed = HermesSlashReply(reply, typed: typed) else {
            throw BotFailure.unsupported
        }
        return parsed
    }

    func checkpoints() async throws -> [HermesCheckpoint]? {
        HermesCheckpoint.list(try await write(reattachesOn: Self.isGoneRuntime) { .rollbackList(runtime: $0) })
    }

    func checkpointDiff(_ hash: String) async throws -> (stat: String, diff: String) {
        let reply = try await write(reattachesOn: Self.isGoneRuntime) { .rollbackDiff(runtime: $0, hash: hash) }
        return (reply["stat"].text ?? "", reply["diff"].text ?? "")
    }

    func restoreCheckpoint(_ hash: String, filePath: String?) async throws -> HermesRollbackOutcome {
        HermesRollbackOutcome(try await write(reattachesOn: Self.isGoneRuntime) {
            .rollbackRestore(runtime: $0, hash: hash, filePath: filePath)
        })
    }

    static func isGoneRuntime(_ error: Error) -> Bool {
        if case BotSettingFailure.rejected(4001, let reason) = error {
            return ["session not found", "not_found", "runtime_retired"].contains(reason)
        }
        return false
    }

    private func write(reattachesOn isReaped: (Error) -> Bool = HermesChatSideTasks.isReaped,
                       _ call: (String) -> HermesCall) async throws -> BotJSON {
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw HermesChatTurnCoordinator.NotSent(underlying: BotFailure.transport)
        }
        var dispatched = false
        do {
            return try await engine.write(call(runtime), attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            if isReaped(error) { onNeedsReattach() }
            throw dispatched ? error : HermesChatTurnCoordinator.NotSent(underlying: error)
        }
    }

    private func mutate(_ operation: HermesCall.SessionMutation.Operation) async throws -> BotJSON {
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw HermesChatTurnCoordinator.NotSent(underlying: BotFailure.transport)
        }
        var dispatched = false
        do {
            return try await engine.mutate(operation, attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            throw dispatched ? error : HermesChatTurnCoordinator.NotSent(underlying: error)
        }
    }

    func complete(_ text: String?) async {
        completionRevision += 1
        let revision = completionRevision
        guard let text, engine.connectionState == .connected, let runtime = engine.runtime else {
            completion = nil
            return
        }
        if let completion, !completion.applies(to: text) { self.completion = nil }
        do { try await Task.sleep(for: completionDelay) } catch { return }
        let reply = try? await engine.request(.completeSlash(text: text, sessionID: runtime), attempt: engine.generation)
        guard revision == completionRevision, !Task.isCancelled else { return }
        let items = (reply?["items"].list ?? []).compactMap { item -> HermesSlashCompletion.Item? in
            guard let value = item["text"].text, !value.isEmpty else { return nil }
            return .init(text: value, display: item["display"].text ?? value, meta: item["meta"].text ?? "")
        }
        completion = items.isEmpty ? nil
            : HermesSlashCompletion(text: text, items: items, replaceFrom: reply?["replace_from"].integer ?? text.unicodeScalars.count)
    }
}
