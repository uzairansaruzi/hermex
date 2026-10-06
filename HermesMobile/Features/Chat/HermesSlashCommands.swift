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

/// Where a typed `/name` goes in a Hermes chat (#1036), in this order.
enum HermesSlashRoute: Equatable {
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
    /// What the composer's panel offers: Hermex's own commands first, then the catalog's.
    private(set) var scope = SlashCommandScope(builtins: SlashCommandCatalog.hermesCommands, isHermes: true)
    /// The newest argument suggestions; nil while none apply.
    private(set) var completion: HermesSlashCompletion?
    /// How long typing must pause before an argument is completed. Tests shorten it.
    @ObservationIgnored var completionDelay: Duration = .milliseconds(150)
    @ObservationIgnored private var completionRevision = 0
    /// The host reaped the runtime (4001): reattach to the stored key.
    @ObservationIgnored var onNeedsReattach: () -> Void = {}
    private let engine: HermesConversation

    init(engine: HermesConversation) {
        self.engine = engine
    }

    /// Reads the catalog for `runtime`. A reply for an attach that is no longer current is
    /// dropped; a failed read keeps the last list, empty until one answers.
    func connect(runtime: String, attempt: Int) async {
        guard engine.generation == attempt, engine.connectionState == .connected,
              let reply = try? await engine.request(.commandsCatalog(sessionID: runtime), attempt: attempt)
        else { return }
        catalog = HermesSlashCatalog(reply)
    }

    /// Where `/name` goes. Hermex's own commands and the held ones resolve without a
    /// catalog; an alias resolves to its command first.
    func route(_ name: String) -> HermesSlashRoute {
        let typed = name.lowercased()
        let canonical = catalog.command(named: typed)?.lowercased() ?? typed
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
