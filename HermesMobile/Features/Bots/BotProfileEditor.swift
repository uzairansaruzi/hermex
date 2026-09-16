import Foundation
import Observation
import UIKit

struct BotProfileCapability: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String?
    var enabled: Bool
}

struct BotProfileDetails: Equatable, Sendable {
    let name: String
    var description: String
    var instructions: String
    var model: ModelCatalogOption?
    var skills: [BotProfileCapability]
    var toolsets: [BotProfileCapability]
    var toolsetsPinned: Bool
    var mcpServers: [BotProfileCapability]

    init(_ payload: BotJSON, expectedName: String) {
        name = payload["name"].text ?? expectedName
        description = payload["description"].text ?? ""
        instructions = payload["soul"].text ?? ""
        let modelID = payload["model"]["default"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = payload["model"]["provider"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model = modelID.isEmpty || provider.isEmpty ? nil : ModelCatalogOption(id: modelID, displayName: modelID, providerID: provider)
        skills = Self.capabilities(payload["skills"], label: "name")
        toolsets = Self.capabilities(payload["toolsets"], label: "label") { row in
            let description = row["description"].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = row["tool_count"].integer.map { String($0) }
            return [description, count].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        toolsetsPinned = payload["toolsets_pinned"].flag == true
        mcpServers = Self.capabilities(payload["mcp_servers"], label: "name") { $0["transport"].text }
    }

    private static func capabilities(_ payload: BotJSON, label: String,
                                     detail: (BotJSON) -> String? = { _ in nil }) -> [BotProfileCapability] {
        var seen = Set<String>()
        return (payload.list ?? []).compactMap { row in
            guard let id = row["name"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let display = row[label].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = display.flatMap { $0.isEmpty ? nil : $0 } ?? id
            return BotProfileCapability(id: id, name: name,
                                        detail: detail(row), enabled: row["enabled"].flag != false)
        }
    }
}

/// One connection/Profile editor. The initial roster row contributes Desktop's
/// appearance revision; `profiles.describe` contributes Profile-scoped content.
/// Successful sections advance their own baseline, while failed sections remain dirty.
@MainActor @Observable final class BotProfileEditor {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }
    enum Field: String, CaseIterable, Hashable, Identifiable {
        case appearance, description, instructions, model, skills, toolsets, mcpServers, avatar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return String(localized: "Appearance")
            case .description: return String(localized: "Description")
            case .instructions: return String(localized: "Instructions")
            case .model: return String(localized: "Default Model")
            case .skills: return String(localized: "Skills")
            case .toolsets: return String(localized: "Toolsets")
            case .mcpServers: return String(localized: "MCP servers")
            case .avatar: return String(localized: "Avatar")
            }
        }
    }
    enum Outcome: Equatable {
        case saved, failed(String), conflict, confirmationRequired
    }
    struct Draft: Equatable, Sendable {
        var appearance: BotProfileAppearance
        var description: String
        var instructions: String
        var model: ModelCatalogOption?
        var skills: [BotProfileCapability]
        var toolsets: [BotProfileCapability]
        var mcpServers: [BotProfileCapability]
    }
    struct ModelConfirmation: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    let server: URL
    let connection: BotConnection
    private(set) var profile: BotProfile
    private(set) var state = LoadState.idle
    private(set) var draft: Draft
    private(set) var modelGroups: [ModelCatalogGroup] = []
    private(set) var outcomes: [Field: Outcome] = [:]
    private(set) var confirmation: ModelConfirmation?
    private(set) var isSaving = false
    private(set) var avatar: UIImage?

    private var baseline: Draft
    private var receivedLook: [String: BotJSON]
    private var lookRevision: Int?
    private var avatarChange = AvatarChange.unchanged
    private var wire: (any BotTransport)?
    private var generation = 0
    private let store: BotConnectionStore
    private let avatarStore: BotAvatarStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let onSaved: () -> Void

    private enum AvatarChange { case unchanged, replace(String), remove }

    init(server: URL, connection: BotConnection, profile: BotProfile, avatar: UIImage?,
         store: BotConnectionStore? = nil, avatarStore: BotAvatarStore? = nil,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onSaved: @escaping () -> Void = {}) {
        self.server = server; self.connection = connection; self.profile = profile; self.avatar = avatar
        self.store = store ?? BotConnectionStore(); self.avatarStore = avatarStore ?? .shared
        self.makeWire = makeWire ?? { BotClient(connection: $0) }; self.onSaved = onSaved
        let empty = Draft(appearance: BotProfileAppearance(profile: profile), description: "", instructions: "",
                          model: nil, skills: [], toolsets: [], mcpServers: [])
        draft = empty; baseline = empty; receivedLook = profile.look; lookRevision = profile.lookRevision
    }

    var dirtyFields: Set<Field> {
        var fields = Set<Field>()
        if draft.appearance != baseline.appearance { fields.insert(.appearance) }
        if draft.description != baseline.description { fields.insert(.description) }
        if draft.instructions != baseline.instructions { fields.insert(.instructions) }
        if draft.model != baseline.model { fields.insert(.model) }
        if draft.skills != baseline.skills { fields.insert(.skills) }
        if draft.toolsets != baseline.toolsets { fields.insert(.toolsets) }
        if draft.mcpServers != baseline.mcpServers { fields.insert(.mcpServers) }
        if case .unchanged = avatarChange {} else { fields.insert(.avatar) }
        return fields
    }
    var canSave: Bool { state == .loaded && !isSaving && !dirtyFields.isEmpty }

    func load() async {
        generation += 1
        let owner = generation
        wire?.close()
        state = .loading; outcomes = [:]; confirmation = nil
        let client = makeWire(connection)
        wire = client
        watchDisconnect(client, owner: owner)
        do {
            try ensureCurrentConnection()
            try await client.connect()
            let detailsPayload = try await client.call("profiles.describe", ["name": .string(profile.id)], validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            let details = BotProfileDetails(detailsPayload, expectedName: profile.id)
            guard details.name == profile.id else { throw BotFailure.wrongIdentity }
            if let options = try? await client.call("model.options", ["include_unconfigured": .bool(false)], validateDispatch: validate(owner)) {
                try ensureOwner(owner, client)
                modelGroups = BotModelCatalog(options).groups
            } else {
                try ensureOwner(owner, client)
                modelGroups = []
            }
            let loaded = Draft(appearance: BotProfileAppearance(profile: profile), description: details.description,
                               instructions: details.instructions, model: details.model, skills: details.skills,
                               toolsets: details.toolsets, mcpServers: details.mcpServers)
            baseline = loaded; draft = loaded; state = .loaded
        } catch is CancellationError {
            if generation == owner { close() }
        } catch {
            guard generation == owner, wire === client else { return }
            client.close(); wire = nil
            state = .failed(error.localizedDescription)
        }
    }

    func close() {
        generation += 1
        wire?.close(); wire = nil
        isSaving = false; confirmation = nil
    }

    /// Backgrounding can make an in-flight write ambiguous. Preserve every
    /// draft and make that uncertainty visible; the next deliberate Save opens
    /// a fresh socket but never retries automatically.
    func suspend() {
        let fields = dirtyFields
        let wasSaving = isSaving
        close()
        if wasSaving {
            for field in fields where outcomes[field] == nil {
                outcomes[field] = .failed(String(localized: "Outcome Uncertain"))
            }
        }
    }

    func setTitle(_ value: String) { draft.appearance.title = value; clearOutcome(.appearance) }
    func setDescription(_ value: String) { draft.description = value; clearOutcome(.description) }
    func setInstructions(_ value: String) { draft.instructions = value; clearOutcome(.instructions) }
    func setModel(_ value: ModelCatalogOption) { draft.model = value; clearOutcome(.model) }

    func setShape(_ shape: BotAvatarShape) {
        draft.appearance.shape = shape.rawValue
        draft.appearance.custom = true
        draft.appearance.imageKind = "shape"
        avatar = nil; avatarChange = .remove
        clearOutcome(.appearance); clearOutcome(.avatar)
    }

    func setColor(_ color: String) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil {
            draft.appearance.shape = BotAvatarShape.circle.rawValue
        }
        draft.appearance.color = color
        draft.appearance.custom = true
        draft.appearance.imageKind = "shape"
        avatar = nil; avatarChange = .remove
        clearOutcome(.appearance)
        clearOutcome(.avatar)
    }

    func resetAppearance() {
        draft.appearance.shape = nil; draft.appearance.color = nil
        draft.appearance.custom = false; draft.appearance.imageKind = nil
        avatar = nil; avatarChange = .remove
        clearOutcome(.appearance); clearOutcome(.avatar)
    }

    func selectAvatar(_ data: Data) throws {
        guard let image = UIImage(data: data), let normalized = Self.avatarDataURL(image) else {
            throw BotProfileEditorImageError.unsupported
        }
        avatar = image; avatarChange = .replace(normalized)
        draft.appearance.custom = true; draft.appearance.imageKind = "photo"
        clearOutcome(.appearance); clearOutcome(.avatar)
    }

    func removeAvatar() {
        avatar = nil; avatarChange = .remove
        draft.appearance.custom = true; draft.appearance.imageKind = "shape"
        clearOutcome(.appearance); clearOutcome(.avatar)
    }

    func setEnabled(_ enabled: Bool, field: Field, id: String) {
        switch field {
        case .skills: update(&draft.skills, id: id, enabled: enabled)
        case .toolsets:
            guard enabled || draft.toolsets.filter(\.enabled).count > 1 else { return }
            update(&draft.toolsets, id: id, enabled: enabled)
        case .mcpServers: update(&draft.mcpServers, id: id, enabled: enabled)
        default: return
        }
        clearOutcome(field)
    }

    func save() async { await save(fields: dirtyFields, confirmedModel: false) }

    func confirmModelChange() async {
        confirmation = nil
        await save(fields: [.model], confirmedModel: true)
    }

    func declineModelChange() {
        confirmation = nil
        outcomes[.model] = .failed(String(localized: "Model confirmation was declined. Your selection is still unsaved."))
    }

    /// Refreshes only Desktop appearance after a compare-and-swap conflict.
    /// Other unsaved Profile fields stay untouched.
    func reloadAppearance() async {
        guard let client = wire else { return }
        let owner = generation
        do {
            let roster = try await client.call("profiles.list", ["include_sessions": .bool(false)], validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard let row = roster["profiles"].list?.first(where: { $0["name"].text == profile.id }),
                  let fresh = BotProfile(row) else { throw BotFailure.wrongIdentity }
            profile = fresh; receivedLook = fresh.look; lookRevision = fresh.lookRevision
            let appearance = BotProfileAppearance(profile: fresh)
            baseline.appearance = appearance; draft.appearance = appearance
            avatarChange = .unchanged; outcomes.removeValue(forKey: .appearance); outcomes.removeValue(forKey: .avatar)
            await avatarStore.refresh([fresh], connectionID: connection.id, using: client,
                                      validateDispatch: validate(owner)) {}
            try ensureOwner(owner, client)
            avatar = avatarStore.images(connectionID: connection.id)[fresh.id]
        } catch {
            guard generation == owner, wire === client else { return }
            outcomes[.appearance] = .failed(error.localizedDescription)
        }
    }

    private func save(fields: Set<Field>, confirmedModel: Bool) async {
        guard state == .loaded, !isSaving, !fields.isEmpty else { return }
        generation += 1
        let owner = generation
        isSaving = true; outcomes = outcomes.filter { !fields.contains($0.key) }
        defer { if generation == owner { isSaving = false } }
        let needsConnect = wire == nil
        let client = wire ?? makeWire(connection)
        wire = client
        watchDisconnect(client, owner: owner)
        let configured = fields.subtracting([.avatar])
        do {
            try ensureCurrentConnection()
            if needsConnect {
                try await client.connect()
                try ensureOwner(owner, client)
            }
            if !configured.isEmpty {
                let reply = try await client.call("profiles.configure", configurePayload(for: configured, confirmedModel: confirmedModel),
                                                  validateDispatch: validate(owner))
                try ensureOwner(owner, client)
                apply(reply, to: configured)
            }
            let appearanceApplied = !configured.contains(.appearance) || outcomes[.appearance] == .saved
            if fields.contains(.avatar), appearanceApplied {
                try await saveAvatar(client, owner: owner)
            } else if fields.contains(.avatar) {
                outcomes[.avatar] = .failed(String(localized: "Needs Attention"))
            }
            if fields.contains(where: { outcomes[$0] == .saved }) { onSaved() }
        } catch {
            guard generation == owner, wire === client else { return }
            for field in fields where outcomes[field] == nil { outcomes[field] = .failed(error.localizedDescription) }
            client.close(); wire = nil
        }
    }

    private func configurePayload(for fields: Set<Field>, confirmedModel: Bool) -> [String: BotJSON] {
        var params: [String: BotJSON] = ["name": .string(profile.id)]
        if fields.contains(.appearance) {
            params["ui_meta"] = .object(["hermes-bots": .object(draft.appearance.merging(into: receivedLook))])
            params["ui_meta_expected_revisions"] = .object(["hermes-bots": .number(Double(lookRevision ?? 0))])
        }
        if fields.contains(.description) { params["description"] = .string(draft.description) }
        if fields.contains(.instructions) { params["soul"] = .string(draft.instructions) }
        if fields.contains(.model), let model = draft.model, let provider = model.providerID {
            params["model"] = .string(model.id); params["provider"] = .string(provider)
            if confirmedModel { params["confirm_expensive_model"] = .bool(true) }
        }
        if fields.contains(.skills) {
            params["disabled_skills"] = .array(draft.skills.filter { !$0.enabled }.map { .string($0.id) })
        }
        if fields.contains(.toolsets) {
            let enabled = draft.toolsets.filter(\.enabled)
            params["enabled_toolsets"] = .array(enabled.count == draft.toolsets.count ? [] : enabled.map { .string($0.id) })
        }
        if fields.contains(.mcpServers) {
            params["enabled_mcp_servers"] = .array(draft.mcpServers.filter(\.enabled).map { .string($0.id) })
        }
        return params
    }

    private func apply(_ reply: BotJSON, to fields: Set<Field>) {
        for field in fields {
            let key: String
            switch field {
            case .appearance: key = "ui_meta"
            case .description: key = "description"
            case .instructions: key = "soul"
            case .model: key = "model"
            case .skills: key = "skills"
            case .toolsets: key = "toolsets"
            case .mcpServers: key = "mcp_servers"
            case .avatar: continue
            }
            if reply["applied"][key].flag == true {
                outcomes[field] = .saved; advanceBaseline(field, reply: reply)
            } else if field == .model, reply["confirm_required"].flag == true {
                outcomes[field] = .confirmationRequired
                confirmation = ModelConfirmation(message: reply["confirm_message"].text ?? String(localized: "Confirm this model change?"))
            } else if field == .appearance, reply["applied"]["ui_meta_conflicts"] != .null {
                outcomes[field] = .conflict
            } else {
                outcomes[field] = .failed(String(localized: "Failed"))
            }
        }
    }

    private func advanceBaseline(_ field: Field, reply: BotJSON) {
        switch field {
        case .appearance:
            draft.appearance.title = draft.appearance.title.trimmingCharacters(in: .whitespacesAndNewlines)
            baseline.appearance = draft.appearance
            receivedLook = draft.appearance.merging(into: receivedLook)
            lookRevision = reply["applied"]["ui_meta_revisions"]["hermes-bots"].integer ?? lookRevision
        case .description:
            draft.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
            baseline.description = draft.description
        case .instructions: baseline.instructions = draft.instructions
        case .model: baseline.model = draft.model
        case .skills: baseline.skills = draft.skills
        case .toolsets: baseline.toolsets = draft.toolsets
        case .mcpServers: baseline.mcpServers = draft.mcpServers
        case .avatar: break
        }
    }

    private func saveAvatar(_ client: any BotTransport, owner: Int) async throws {
        let params: [String: BotJSON]
        switch avatarChange {
        case .unchanged: return
        case .replace(let data): params = ["name": .string(profile.id), "asset": .string("avatar"), "data": .string(data)]
        case .remove: params = ["name": .string(profile.id), "asset": .string("avatar"), "clear": .bool(true)]
        }
        let reply = try await client.call("profiles.set_asset", params, validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard reply["ok"].flag == true, reply["asset"].text == "avatar" else { throw BotFailure.unsupported }
        avatarStore.setImage(avatar, connectionID: connection.id, profile: profile.id, revision: lookRevision)
        avatarChange = .unchanged; outcomes[.avatar] = .saved
    }

    private func update(_ values: inout [BotProfileCapability], id: String, enabled: Bool) {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].enabled = enabled
    }

    private func clearOutcome(_ field: Field) {
        outcomes.removeValue(forKey: field)
        if field == .model { confirmation = nil }
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
        client.onDisconnect = { [weak self] error in
            guard let self, self.generation == owner else { return }
            self.wire = nil
            for field in self.dirtyFields where self.outcomes[field] == nil {
                self.outcomes[field] = .failed(error.localizedDescription)
            }
        }
    }

    private static func avatarDataURL(_ image: UIImage) -> String? {
        var target = image
        let longest = max(image.size.width, image.size.height)
        if longest > 1_024 {
            let scale = 1_024 / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            target = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        if let data = target.pngData(), data.count <= 2_000_000 {
            return "data:image/png;base64," + data.base64EncodedString()
        }
        for quality in [0.88, 0.72, 0.56, 0.4] {
            if let data = target.jpegData(compressionQuality: quality), data.count <= 2_000_000 {
                return "data:image/jpeg;base64," + data.base64EncodedString()
            }
        }
        return nil
    }
}

enum BotProfileEditorImageError: LocalizedError {
    case unsupported
    var errorDescription: String? { String(localized: "Could not decode this image.") }
}
