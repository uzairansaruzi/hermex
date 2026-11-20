import Foundation
import Observation

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
        var sharesCredentials = true
        var instructions = ""
        var skipsBundledSkills = false
    }

    let server: URL
    let connection: BotConnection
    let source: BotProfile?
    private(set) var draft: Draft
    private(set) var phase = Phase.editing
    private(set) var isLoading = false
    private(set) var outcomes: [Step: Outcome] = [:]
    private(set) var modelGroups: [ModelCatalogGroup] = []
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
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }; self.onCreated = onCreated
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

    var name: String { BotProfileName.slug(from: draft.title) }
    var nameIsTaken: Bool { taken.contains(name) }
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
    var needsAttention: Bool { note != nil || outcomes.values.contains { $0 != .done } }

    func setTitle(_ value: String) { draft.title = value; draft.appearance.title = value }
    func setRole(_ value: String) { draft.role = value }
    func setModel(_ value: ModelCatalogOption?) { draft.model = value }
    func setSharesCredentials(_ value: Bool) { draft.sharesCredentials = value }
    func setInstructions(_ value: String) { draft.instructions = value }
    func setSkipsBundledSkills(_ value: Bool) { draft.skipsBundledSkills = value }
    func setShape(_ shape: BotAvatarShape) {
        draft.appearance.shape = shape.rawValue; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
        draft.appearance.generated = nil
    }
    func setGenerated(_ generated: BotGeneratedAvatar) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil { draft.appearance.shape = BotAvatarShape.circle.rawValue }
        draft.appearance.generated = generated; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    var holdsConnection: Bool { wire != nil }

    func sendAvatarPrompt(_ prompt: String) async throws -> String {
        guard let client = wire else { throw BotFailure.stale }
        return try await BotAvatarGeneration.ask(prompt, profile: "default", transport: client, validateDispatch: validate(generation))
    }
    func setColor(_ hex: String) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil { draft.appearance.shape = BotAvatarShape.circle.rawValue }
        draft.appearance.color = hex; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    func setExpression(_ expression: BotAvatarExpression) {
        draft.appearance.expression = expression == .neutral ? nil : expression.rawValue
    }

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
            if let options = try? await client.call(.configuredModelOptions, validateDispatch: validate(owner)) {
                try ensureOwner(owner, client)
                modelGroups = HermesModelCatalog(options).groups
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
            guard generation == owner else { return }
            if !(error is BotCreatorStop), let step = Step.allCases.first(where: { outcomes[$0] == nil }) {
                outcomes[step] = error as? BotFailure == .transport ? .uncertain : .failed(error.localizedDescription)
            }
            phase = .editing
            client.close(); wire = nil
        }
    }

    private func createProfile(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.profile] == .done { return }
        if outcomes[.profile] == .uncertain {
            let roster = try await client.call(.profilesList(includeSessions: false), validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            if rows.contains(where: { $0["name"].text == name }) { outcomes[.profile] = .done; return }
        }
        var profile = HermesCall.NewProfile(name: name, sharesCredentials: draft.sharesCredentials)
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { profile.description = role }
        if let source {
            profile.cloneFrom = source.id
        } else {
            if !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.soul = draft.instructions
            }
            profile.skipsBundledSkills = draft.skipsBundledSkills
        }
        if let model = draft.model, let provider = model.providerID {
            profile.model = HermesCall.Model(id: model.id, provider: provider)
        }
        do {
            let reply = try await client.call(.profilesCreate(profile), validateDispatch: validate(owner))
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

    private func configureLook(_ client: any BotTransport, owner: Int) async {
        if outcomes[.look] == .done { return }
        var look = draft.appearance
        look.title = draft.title
        do {
            let reply = try await client.call(.profilesConfigure(.init(name: name, look: .init(fields: look.merging(into: [:]), revision: 0))),
                                              validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            outcomes[.look] = reply["applied"]["ui_meta"].flag == true
                ? .done : .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        } catch {
            guard generation == owner else { return }
            outcomes[.look] = .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        }
    }

    private func ensureChat(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.chat] == .done { return }
        if try await findChat(client, owner: owner) { outcomes[.chat] = .done; return }
        await client.keepPlatformNote(profile: name)
        let created = try await client.call(.sessionCreate(profile: name), validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard let runtime = created["session_id"].text, !runtime.isEmpty else { throw BotFailure.unsupported }
        if client.speaksCanonicalProtocol { outcomes[.chat] = .done; return }
        do {
            _ = try await client.call(.sessionTitle(sessionID: runtime), validateDispatch: validate(owner))
            try ensureOwner(owner, client)
        } catch BotFailure.rejected(4022) {
            try ensureOwner(owner, client)
            guard try await findChat(client, owner: owner) else { throw BotFailure.unsupported }
        }
        outcomes[.chat] = .done
    }

    private func findChat(_ client: any BotTransport, owner: Int) async throws -> Bool {
        let lookup = try await client.call(.sessionList(profile: name), validateDispatch: validate(owner))
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

private struct BotCreatorStop: Error {}
