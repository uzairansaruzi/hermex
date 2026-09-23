import Foundation
import Observation

/// Hermes Profile names as the host validates them: `[a-z0-9][a-z0-9_-]{0,63}`,
/// never `default` or another reserved word. The slug is derived from the display
/// name the user types, so the roster title and the folder name stay related.
enum BotProfileName {
    static let reserved: Set<String> = ["hermes", "default", "test", "tmp", "root", "sudo"]

    static func slug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else { pendingDash = true }
        }
        return String(result.prefix(64))
    }

    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64, !reserved.contains(name) else { return false }
        guard ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }
}

/// One bot creation or duplication for one connection. Setup is three host writes
/// in order: the Profile (`profiles.create`), its look (`profiles.configure`) and
/// its canonical "Bot Chat" (`session.create` + `session.title`). Each step records
/// its own outcome; Try Again repeats only the steps that are not done, and a
/// step whose reply was lost re-reads the host before writing again, so a retry
/// never mints a second Profile or a second chat.
@MainActor @Observable final class BotCreator {
    enum Step: CaseIterable, Identifiable {
        case profile, look, chat
        var id: Self { self }
        var title: String {
            switch self {
            case .profile: return String(localized: "Profile")
            case .look: return String(localized: "Look")
            case .chat: return String(localized: "Bot Chat")
            }
        }
    }
    enum Outcome: Equatable { case done, failed(String), uncertain }
    enum Phase: Equatable { case editing, creating, created }

    struct Draft: Equatable {
        var title = ""
        var role = ""
        var appearance = BotProfileAppearance(look: [:], fallbackTitle: "")
        var model: ModelCatalogOption?
        /// On: `share_auth`, the new bot reads the host's saved sign-ins and keys in
        /// place. Off: `mirror_credentials: false`, the bot starts with none. Values
        /// never travel to the phone either way.
        var sharesCredentials = true
        /// New bots only: becomes the Profile's `SOUL.md` when it has text; empty
        /// keeps the host's default. A duplicate copies the source's instead.
        var instructions = ""
        /// New bots only: `no_skills`, so the host seeds only its essential skills.
        /// The host refuses it with `clone_from`, since a copy brings the source's skills.
        var skipsBundledSkills = false
    }

    let server: URL
    let connection: BotConnection
    /// The bot being duplicated, whose config, skills and instructions the host clones.
    let source: BotProfile?
    private(set) var draft: Draft
    private(set) var phase = Phase.editing
    /// True while the socket and model inventory are being opened; Create waits for it.
    private(set) var isLoading = false
    private(set) var outcomes: [Step: Outcome] = [:]
    private(set) var modelGroups: [ModelCatalogGroup] = []
    /// One-line note after a successful create when the host reports the bot
    /// ended up without a model, so the user knows to finish setup.
    private(set) var note: String?

    private var taken: Set<String>
    private var wire: (any BotTransport)?
    private var generation = 0
    private let store: BotConnectionStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let onCreated: (String) -> Void

    init(server: URL, connection: BotConnection, roster: [BotProfile], source: BotProfile? = nil,
         store: BotConnectionStore? = nil, makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onCreated: @escaping (String) -> Void = { _ in }) {
        self.server = server; self.connection = connection; self.source = source
        self.store = store ?? BotConnectionStore()
        self.makeWire = makeWire ?? { BotClient(connection: $0) }; self.onCreated = onCreated
        taken = Set(roster.map(\.id))
        var draft = Draft()
        if let source {
            draft.title = String(localized: "\(source.name) copy")
            draft.role = source.description ?? ""
            draft.appearance = BotProfileAppearance(profile: source)
            draft.appearance.imageKind = "shape"
        } else {
            draft.appearance.shape = BotAvatarShape.circle.rawValue
            draft.appearance.color = "#38bdf8"
            draft.appearance.custom = true
            draft.appearance.imageKind = "shape"
        }
        self.draft = draft
    }

    /// The Profile folder name the host will get; empty when the title yields none.
    var name: String { BotProfileName.slug(from: draft.title) }
    var nameIsTaken: Bool { taken.contains(name) }
    /// True once a create attempt has written anything: the name is committed and
    /// Try Again resumes the same bot instead of starting another.
    var hasStarted: Bool { !outcomes.isEmpty }
    var nameProblem: String? {
        let name = self.name
        if hasStarted || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if name.isEmpty || !BotProfileName.isValid(name) {
            return String(localized: "Use letters or numbers; “\(name.isEmpty ? draft.title : name)” is not allowed as a Profile name.")
        }
        if nameIsTaken { return String(localized: "A bot named “\(name)” already exists on this Hermes.") }
        return nil
    }
    var canCreate: Bool {
        phase == .editing && !isLoading && BotProfileName.isValid(name) && (hasStarted || !nameIsTaken)
    }
    var isDuplicate: Bool { source != nil }
    /// True after a create that finished with something left to do: a look that
    /// did not save or a bot with no model. The sheet stays up to say so.
    var needsAttention: Bool { note != nil || outcomes.values.contains { $0 != .done } }

    func setTitle(_ value: String) { draft.title = value; draft.appearance.title = value }
    func setRole(_ value: String) { draft.role = value }
    func setModel(_ value: ModelCatalogOption?) { draft.model = value }
    func setSharesCredentials(_ value: Bool) { draft.sharesCredentials = value }
    func setInstructions(_ value: String) { draft.instructions = value }
    func setSkipsBundledSkills(_ value: Bool) { draft.skipsBundledSkills = value }
    func setShape(_ shape: BotAvatarShape) {
        draft.appearance.shape = shape.rawValue; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    func setColor(_ hex: String) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil { draft.appearance.shape = BotAvatarShape.circle.rawValue }
        draft.appearance.color = hex; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    func setExpression(_ expression: BotAvatarExpression) {
        draft.appearance.expression = expression == .neutral ? nil : expression.rawValue
    }

    /// Opens the socket and reads the model inventory. A failure here leaves the
    /// picker empty; the create itself reconnects if needed.
    func load() async {
        generation += 1
        let owner = generation
        wire?.close()
        let client = makeWire(connection)
        wire = client
        isLoading = true
        defer { if generation == owner { isLoading = false } }
        watchDisconnect(client, owner: owner)
        do {
            try ensureCurrentConnection()
            try await client.connect()
            try ensureOwner(owner, client)
            if let options = try? await client.call("model.options", ["include_unconfigured": .bool(false)], validateDispatch: validate(owner)) {
                try ensureOwner(owner, client)
                modelGroups = BotModelCatalog(options).groups
            }
        } catch {
            guard generation == owner, wire === client else { return }
            client.close(); wire = nil
        }
    }

    func close() {
        generation += 1
        wire?.close(); wire = nil
        isLoading = false
        if phase == .creating {
            phase = .editing
            for step in Step.allCases where outcomes[step] == nil { outcomes[step] = .uncertain }
        }
    }

    /// Runs the steps that are not done yet. Never called twice concurrently.
    func create() async {
        guard canCreate else { return }
        generation += 1
        let owner = generation
        phase = .creating; note = nil
        outcomes = outcomes.filter { $0.value == .done || $0.value == .uncertain }
        let needsConnect = wire == nil
        let client = wire ?? makeWire(connection)
        wire = client
        watchDisconnect(client, owner: owner)
        do {
            try ensureCurrentConnection()
            if needsConnect {
                try await client.connect()
                try ensureOwner(owner, client)
            }
            try await createProfile(client, owner: owner)
            await configureLook(client, owner: owner)
            try await ensureChat(client, owner: owner)
            guard generation == owner else { return }
            phase = .created
            onCreated(name)
        } catch {
            // A disconnect clears `wire` before the suspended call throws, so only the
            // generation decides whether this attempt still owns the sheet.
            guard generation == owner else { return }
            if !(error is BotCreatorStop), let step = Step.allCases.first(where: { outcomes[$0] == nil }) {
                // A dropped connection mid-write leaves that write's fate unknown; the
                // next attempt re-reads the host before writing again.
                outcomes[step] = error as? BotFailure == .transport ? .uncertain : .failed(error.localizedDescription)
            }
            phase = .editing
            client.close(); wire = nil
        }
    }

    private func createProfile(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.profile] == .done { return }
        if outcomes[.profile] == .uncertain {
            let roster = try await client.call("profiles.list", ["include_sessions": .bool(false)], validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            if rows.contains(where: { $0["name"].text == name }) { outcomes[.profile] = .done; return }
        }
        var params: [String: BotJSON] = ["name": .string(name)]
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { params["description"] = .string(role) }
        if let source {
            params["clone_from"] = .string(source.id)
        } else {
            if !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                params["soul"] = .string(draft.instructions)
            }
            if draft.skipsBundledSkills { params["no_skills"] = .bool(true) }
        }
        if let model = draft.model, let provider = model.providerID {
            params["model"] = .string(model.id); params["provider"] = .string(provider)
        }
        if draft.sharesCredentials { params["share_auth"] = .bool(true) }
        else { params["mirror_credentials"] = .bool(false) }
        do {
            let reply = try await client.call("profiles.create", params, validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard reply["ok"].flag == true else { throw BotFailure.unsupported }
            outcomes[.profile] = .done
            taken.insert(name)
            if reply["model_set"].flag != true, reply["mirrored"]["model_inherited"].flag != true {
                note = String(localized: "No model is set for this bot yet. Pick one in Edit or in Hermes Desktop before chatting.")
            }
        } catch BotFailure.rejected(4062) {
            outcomes[.profile] = .failed(String(localized: "Hermes refused this name. It may already exist on the host."))
            throw BotCreatorStop()
        }
    }

    /// The look is cosmetic: a failure is reported but does not stop the chat step.
    private func configureLook(_ client: any BotTransport, owner: Int) async {
        if outcomes[.look] == .done { return }
        var look = draft.appearance
        look.title = draft.title
        do {
            let reply = try await client.call("profiles.configure", [
                "name": .string(name),
                "ui_meta": .object(["hermes-bots": .object(look.merging(into: [:]))]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(0)])
            ], validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            outcomes[.look] = reply["applied"]["ui_meta"].flag == true
                ? .done : .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        } catch {
            guard generation == owner else { return }
            outcomes[.look] = .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        }
    }

    /// Adopt-before-mint, as Desktop: an existing "Bot Chat" row is the bot's chat
    /// and is never duplicated. Only a confirmed absence creates one.
    private func ensureChat(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.chat] == .done { return }
        if try await findChat(client, owner: owner) { outcomes[.chat] = .done; return }
        let created = try await client.call("session.create", [
            "profile": .string(name), "title": .string(BotConversation.canonicalTitle),
            "hidden": .bool(true), "follow_profile_config": .bool(true)
        ], validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard let runtime = created["session_id"].text, !runtime.isEmpty else { throw BotFailure.unsupported }
        do {
            // The created row is lazy; the title write persists it so the roster and
            // the phone's exact-title lookup find it before any prompt.
            _ = try await client.call("session.title", ["session_id": .string(runtime), "title": .string(BotConversation.canonicalTitle)],
                                      validateDispatch: validate(owner))
            try ensureOwner(owner, client)
        } catch BotFailure.rejected(4022) {
            // Another writer took the title in between; that chat is the bot's.
            try ensureOwner(owner, client)
            guard try await findChat(client, owner: owner) else { throw BotFailure.unsupported }
        }
        outcomes[.chat] = .done
    }

    private func findChat(_ client: any BotTransport, owner: Int) async throws -> Bool {
        let lookup = try await client.call("session.list", [
            "profile": .string(name), "title": .string(BotConversation.canonicalTitle), "include_hidden": .bool(true)
        ], validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
        return !rows.isEmpty
    }

    private func validate(_ owner: Int) -> () throws -> Void { { [weak self] in
        guard let self, self.generation == owner else { throw BotFailure.stale }
        try self.ensureCurrentConnection()
    } }

    private func ensureOwner(_ owner: Int, _ client: any BotTransport) throws {
        guard generation == owner, wire === client, !Task.isCancelled else { throw BotFailure.stale }
        try ensureCurrentConnection()
    }

    private func ensureCurrentConnection() throws {
        guard try store.load(server: server)?.id == connection.id else { throw BotFailure.stale }
    }

    private func watchDisconnect(_ client: any BotTransport, owner: Int) {
        client.onDisconnect = { [weak self] _ in
            guard let self, self.generation == owner else { return }
            self.wire = nil
        }
    }
}

/// Ends a create after a step recorded its own failure message.
private struct BotCreatorStop: Error {}
