import Foundation
import Observation

/// What a Hermes host's `commands.catalog` lists (#1036): its registry, quick and plugin
/// commands with their aliases, and its skills. The host lists aliases only in `canon`, and
/// skills only in `skills`, so a command row is a `pairs` row whose key `canon` knows.
struct HermesSlashCatalog: Equatable {
    /// The host's commands in its own order, aliases attached. Never a skill.
    private(set) var commands: [AgentCommand] = []
    /// Every command name and alias, lowercased and without its `/`, to its canonical name.
    private(set) var canonical: [String: String] = [:]
    /// The host's skills that no command shadows (`BotSlashCatalog.skills`).
    private(set) var skills: [SkillSlashSuggestion] = []
    /// The names and aliases, lowercased, whose argument the host completes: every command
    /// the host runs, so neither Hermex's own nor a held one.
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
            [alias, name.lowercased()].contains {
                SlashCommandCatalog.hermesCommand(named: $0) != nil || SlashCommandCatalog.hermesHeldNames.contains($0)
            } ? nil : alias
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

    /// The canonical name `name` (a command or one of its aliases) runs, or nil.
    func command(named name: String) -> String? { canonical[name.lowercased()] }

    /// A `/name` key's name: one word, no slash.
    private static func name(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), key.hasPrefix("/") else { return nil }
        let name = String(key.dropFirst())
        guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return name
    }
}

/// What a Hermes chat in `ChatView` lets the user do (#1145). A bot's Bot Chat is that bot's one
/// conversation (#1127 decision 3): nothing in it starts or opens another chat, renames it,
/// branches it or rewinds it, and its Profile chip picks no other Profile. Its side commands
/// (`/btw`, `/background`, `/goal`, `/yolo`, `/compress`) run as in any session. The slash
/// commands, the message menu and the composer all read this one value.
enum HermesChatPolicy: Equatable {
    case session
    /// A bot's Bot Chat: its canonical chat, or a Bot Chat row opened by its key.
    case botChat

    /// A Bot Chat's own target is `.canonicalChat`; a session target is one only when opened from
    /// a Bot Chat row, which names its `botChatRoot`.
    init(target: ConversationTarget, botChatRoot: String? = nil) {
        if case .canonicalChat = target { self = .botChat } else { self = botChatRoot == nil ? .session : .botChat }
    }

    /// Why `/name` (typed, after any alias resolved to `canonical`) does not run here, or nil
    /// when it does. A refused command is also left out of the composer's panel.
    func refusal(typed name: String, canonical: String) -> String? {
        guard self == .botChat else { return nil }
        // `/reset` and `/fork` are the host's aliases, named too for a catalog not read yet.
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

    /// Edit, Regenerate and Fork From Here; Retry under a failed turn stays, as in Bot Chat.
    var offersHistoryActions: Bool { self == .session }
    /// The Profile chip starts a new chat in the Profile it picks.
    var picksProfile: Bool { self == .session }
    /// The host delivers `@`mentions only in a Bot Chat (`tools/bot_mode_dm.py`).
    var offersMentions: Bool { self == .botChat }
}

/// Where a typed `/name` goes in a Hermes chat (#1036), in this order.
enum HermesSlashRoute: Equatable {
    /// Not in this chat (`HermesChatPolicy`): the copy says why, and nothing is sent.
    case refused(String)
    /// One of Hermex's own commands (`SlashCommandCatalog.hermesCommands`), by its handler.
    case appOwned(SlashCommand)
    /// Held until #702 slice 2.3: it would rewrite history or move chats behind the phone's back.
    case held
    /// A host skill: `command.dispatch` expands it into the prompt that is sent.
    case skill(SkillSlashSuggestion)
    /// Any other command or alias the catalog lists: `slash.exec` runs the typed line.
    case host
    /// Not a command this host knows: sent as typed.
    case text
}

/// What the host made of a slash command (`slash.exec`, or `command.dispatch` for a skill).
enum HermesSlashReply: Equatable {
    /// Shown as a notice; nothing is sent.
    case notice(String)
    /// `message` goes out as a prompt, once, after `notice`. `shown` is its transcript row.
    case send(message: String, shown: String, notice: String?)
    /// `message` goes into the composer, after `notice`.
    case prefill(message: String, notice: String?)
    /// Run `/target` instead, with the typed argument.
    case alias(target: String)

    /// Reads one reply, or nil for a shape this app does not know. `typed` is the line the
    /// user ran, which a skill's prompt row shows when the host names no `display`.
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
            // A skill's message is the expanded skill, never shown; the host projects the
            // typed line over it once stored.
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

    /// Terminal output as a code block, so its line breaks and columns survive Markdown.
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

/// The host's suggestions for a command's argument (`complete.slash`), for `text`.
struct HermesSlashCompletion: Equatable {
    struct Item: Equatable, Identifiable {
        let text: String
        let display: String
        let meta: String
        var id: String { text }
    }

    /// The draft up to the caret these answer.
    let text: String
    let items: [Item]
    /// Where in `text`, in Unicode scalars, a picked item's text replaces the rest.
    let replaceFrom: Int

    /// What these suggestions keep: `text` up to `replaceFrom`.
    private var head: String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, replaceFrom))))
    }

    /// Whether these suggestions still fit `current`, the draft up to the caret now: it keeps
    /// their head, and only the word being completed follows it.
    func applies(to current: String) -> Bool {
        current.hasPrefix(head) && !current.unicodeScalars.dropFirst(head.unicodeScalars.count)
            .contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// The draft up to the caret with `item` in place of the word being completed.
    func applying(_ item: Item) -> String { head + item.text }
}

/// A Hermes session's slash commands in the main chat (#1036). `HermesChatTurnCoordinator`
/// owns it and reads the catalog on each connect. The panel ranks the catalog on the phone;
/// only a command's argument stage asks the host (`complete.slash`), debounced, and only the
/// newest reply is kept. Everything lives with the chat: nothing is cached or persisted.
///
/// Hermex runs its own commands (`SlashCommandCatalog.hermesCommands`) and holds the ones
/// that wait on #702; every other catalog command runs on the host through `slash.exec`, a
/// skill through `command.dispatch`, each once.
@MainActor @Observable final class HermesSlashCommands {
    private(set) var catalog = HermesSlashCatalog() {
        didSet { scope.hostCommands = catalog.hostArgumentNames }
    }
    /// What the composer's panel offers: Hermex's own commands first, then the catalog's, both
    /// without what the chat's policy refuses.
    private(set) var scope: SlashCommandScope
    /// The catalog's commands the panel lists: those the chat's policy does not refuse.
    var commands: [AgentCommand] {
        guard policy == .botChat else { return catalog.commands }
        return catalog.commands.filter { command in
            command.name.map { policy.refusal(typed: $0, canonical: $0) == nil } ?? true
        }
    }
    /// The newest argument suggestions; nil while none apply.
    private(set) var completion: HermesSlashCompletion?
    /// How long typing must pause before an argument is completed. Tests shorten it.
    @ObservationIgnored var completionDelay: Duration = .milliseconds(150)
    @ObservationIgnored private var completionRevision = 0
    /// The host reaped the runtime (4001): reattach to the stored key.
    @ObservationIgnored var onNeedsReattach: () -> Void = {}
    let policy: HermesChatPolicy
    private let engine: HermesConversation

    init(engine: HermesConversation, policy: HermesChatPolicy = .session) {
        self.engine = engine
        self.policy = policy
        scope = SlashCommandScope(builtins: SlashCommandCatalog.hermesCommands.filter {
            policy.refusal(typed: $0.name, canonical: $0.name) == nil
        }, isHermes: true)
    }

    /// Reads the catalog for `runtime`. A reply for an attach that is no longer current is
    /// dropped; a failed read keeps the last list, empty until one answers.
    func connect(runtime: String, attempt: Int) async {
        guard engine.generation == attempt, engine.connectionState == .connected,
              let reply = try? await engine.request(.commandsCatalog(sessionID: runtime), attempt: attempt)
        else { return }
        catalog = HermesSlashCatalog(reply)
    }

    /// Where `/name` goes. What the chat's policy refuses, Hermex's own commands and the held
    /// ones resolve without a catalog; an alias resolves to its command first.
    func route(_ name: String) -> HermesSlashRoute {
        let typed = name.lowercased()
        let canonical = catalog.command(named: typed)?.lowercased() ?? typed
        if let refusal = policy.refusal(typed: name, canonical: canonical) { return .refused(refusal) }
        if let command = SlashCommandCatalog.hermesCommand(named: typed) ?? SlashCommandCatalog.hermesCommand(named: canonical) {
            return .appOwned(command)
        }
        if SlashCommandCatalog.hermesHeldNames.contains(typed) || SlashCommandCatalog.hermesHeldNames.contains(canonical) {
            return .held
        }
        if let skill = SlashSkillFormatter.skill(named: name, in: catalog.skills) { return .skill(skill) }
        return catalog.command(named: typed) == nil ? .text : .host
    }

    // MARK: Running

    /// Runs one typed line on the host. Throws `NotSent` when it never went out, and the
    /// host's refusal as `BotSettingFailure`.
    func run(_ line: String) async throws -> HermesSlashReply {
        let reply = try await write { .slashExec(sessionID: $0, command: line) }
        guard let parsed = HermesSlashReply(reply, typed: line) else { throw BotFailure.unsupported }
        return parsed
    }

    /// `/title` (#1048): renames the session on its runtime and returns the title the host
    /// kept. A title in use or too long throws the host's message as `BotSettingFailure`.
    func rename(_ title: String) async throws -> String {
        let reply = try await write { .sessionRename(runtime: $0, title: title) }
        return reply["title"].text.flatMap { $0.isEmpty ? nil : $0 } ?? title
    }

    /// Expands `skill` with `argument` into the prompt to send.
    func expand(_ skill: SkillSlashSuggestion, argument: String, typed: String) async throws -> HermesSlashReply {
        let reply = try await write { .commandDispatch(name: skill.name, argument: argument, sessionID: $0) }
        guard reply["type"].text == "skill", let parsed = HermesSlashReply(reply, typed: typed) else {
            throw BotFailure.unsupported
        }
        return parsed
    }

    /// One write bound to the attached runtime. Throws `NotSent` when it never went out; a
    /// reaped runtime also reattaches.
    private func write(_ call: (String) -> HermesCall) async throws -> BotJSON {
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw HermesChatTurnCoordinator.NotSent(underlying: BotFailure.transport)
        }
        var dispatched = false
        do {
            return try await engine.write(call(runtime), attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            if HermesChatSideTasks.isReaped(error) { onNeedsReattach() }
            throw dispatched ? error : HermesChatTurnCoordinator.NotSent(underlying: error)
        }
    }

    // MARK: Argument completion

    /// Completes the argument in `text` (the draft up to the caret) after a pause in typing;
    /// nil clears it. Cancelling the calling task drops the request, so only the newest
    /// call's reply is ever kept.
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
