import Foundation
import Observation

@MainActor @Observable final class BotChatControls {
    struct Context: Equatable {
        let connectionID: UUID
        let profile: String
        let runtime: String
        let generation: Int
    }
    enum Change: Equatable {
        case model(ModelCatalogOption), effort(String), fast(Bool)
    }
    struct Action: Identifiable, Equatable {
        let id = UUID()
        let context: Context
        let change: Change
        let expectedModel: ModelCatalogOption?
    }
    struct Confirmation: Identifiable {
        let action: Action
        let message: String
        var token: String? = nil
        var id: UUID { action.id }
    }

    typealias Mutate = (HermesCall.SessionMutation.Operation, @escaping () throws -> Void) async throws -> BotJSON

    private(set) var catalog = HermesModelCatalog(.null)
    private(set) var effort: String?
    private(set) var fast: Bool?
    private(set) var pendingModel: ModelCatalogOption?
    @ObservationIgnored var onPickedModelActive: ((ModelCatalogOption) -> Void)?
    private var deferredPick: (model: ModelCatalogOption, from: ModelCatalogOption?)?
    private var heldConfirmation: BotJSON?
    private(set) var confirmation: Confirmation?
    private(set) var errorMessage: String?
    private(set) var isApplying = false
    private(set) var isLoading = false
    private(set) var context: Context?
    private var refused: Set<String> = []
    private var readTask: Task<Void, Never>?
    private var readAgain = false
    private var readRevision = 0
    private var activeAction: UUID?
    private var consumed = Set<UUID>()
    private var wire: (any BotTransport)?
    private var mutate: Mutate?
    private var lastContext: Context?

    var showsFast: Bool {
        guard fast != nil, let active = catalog.active else { return false }
        return fast == true || catalog.capabilities[active.favoriteKey]?["fast"].flag != false
    }

    var supportsEffort: Bool {
        guard let active = catalog.active else { return false }
        return catalog.capabilities[active.favoriteKey]?["reasoning"].flag != false
    }
    private var unavailable: Set<String> { refused.union(wire?.unavailableMethods ?? []) }
    var mayChangeEffort: Bool { mayChangeModel && supportsEffort }
    var mayChangeFast: Bool { mayChangeModel && showsFast }

    var mayChangeModel: Bool { context != nil && !isApplying && !isLoading && !unavailable.contains("model.options") && !unavailable.contains("config.set") && catalog.active != nil }

    func connect(_ context: Context, wire: any BotTransport, mutate: Mutate? = nil) async {
        disconnect()
        if lastContext?.connectionID != context.connectionID || lastContext?.profile != context.profile {
            pendingModel = nil; refused = []; errorMessage = nil
        }
        if lastContext?.runtime != context.runtime { pendingModel = nil; deferredPick = nil; heldConfirmation = nil }
        lastContext = context
        catalog = HermesModelCatalog(.null); effort = nil; fast = nil
        self.context = context; self.wire = wire; self.mutate = mutate
        await reload()
        if self.context == context, let held = heldConfirmation {
            heldConfirmation = nil
            receiveDeferredPickUpdate(held)
        }
    }

    func clearError() {
        if errorMessage != nil { errorMessage = nil }
    }

    func disconnect() {
        if let activeAction, consumed.contains(activeAction) {
            errorMessage = BotSettingFailure.unknownOutcome.localizedDescription
        }
        context = nil; wire = nil; mutate = nil
        readTask?.cancel(); readTask = nil; readAgain = false; readRevision += 1
        confirmation = nil; activeAction = nil; isApplying = false; isLoading = false
        consumed.removeAll()
    }

    func snapshot(_ info: BotJSON) {
        effort = info["reasoning_effort"].text
        fast = info["fast"].flag
        if let pendingModel, let reported = info["model"].text, reported != pendingModel.id {
            self.pendingModel = nil
        }
    }

    func refresh() {
        guard context != nil else { return }
        if readTask != nil { readAgain = true; return }
        readTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.readAgain = false
                await self.reload()
            } while self.readAgain && !Task.isCancelled
            guard !Task.isCancelled else { return }
            self.readTask = nil
            self.settleDeferredPick()
        }
    }

    func reload() async {
        guard let owner = context, let wire else { return }
        readRevision += 1
        let revision = readRevision
        isLoading = true
        defer {
            if context == owner && revision == readRevision { isLoading = false }
            settleDeferredPick()
        }
        let call = HermesCall.modelOptions(sessionID: owner.runtime, profile: owner.profile)
        guard !unavailable.contains(call.method) else { return }
        do {
            let result = try await wire.call(call)
            guard context == owner, revision == readRevision, !Task.isCancelled else { return }
            guard result["providers"].list != nil else { throw BotFailure.unsupported }
            catalog = HermesModelCatalog(result)
            if let pendingModel, catalog.active?.matchesSelection(modelID: pendingModel.id, providerID: pendingModel.providerID) == true {
                self.pendingModel = nil
            }
        } catch {
            guard context == owner, revision == readRevision, !Task.isCancelled else { return }
            if isRefused(error) { refused.insert(call.method) }
            else if !isUnsupported(error), error as? BotFailure != .transport { errorMessage = error.localizedDescription }
        }
    }

    func awaitsDeferredPick(named model: String?) -> Bool {
        model != nil && model == deferredPick?.model.id
    }

    func dropDeferredPick() { deferredPick = nil }

    func holdDeferredPickUpdate(_ payload: BotJSON) {
        if receiveDeferredPickRefusal(payload) { return }
        if deferredPick != nil, payload["status"].text == "confirmation_required" { heldConfirmation = payload }
    }

    private func receiveDeferredPickRefusal(_ payload: BotJSON) -> Bool {
        guard payload["operation"].text == "model", payload["status"].text == "refused",
              let refused = payload["target_model"].text, refused == deferredPick?.model.id else { return false }
        deferredPick = nil; heldConfirmation = nil
        return true
    }

    private func settleDeferredPick() {
        guard let pick = deferredPick, context != nil, readTask == nil, !isLoading, !isApplying,
              let active = catalog.active else { return }
        if active.matchesSelection(modelID: pick.model.id, providerID: pick.model.providerID) {
            deferredPick = nil
            onPickedModelActive?(pick.model)
        } else if active.favoriteKey != pick.from?.favoriteKey {
            deferredPick = nil
        }
    }

    func prepare(_ change: Change) -> Action? {
        guard let context, allowed(change) else { return nil }
        return Action(context: context, change: change, expectedModel: catalog.active)
    }

    func cancelConfirmation() { confirmation = nil }
    func confirm() async {
        guard let pending = confirmation else { return }
        await confirm(pending)
    }

    func confirm(_ pending: Confirmation) async {
        guard allowed(pending.action.change) else { return }
        confirmation = nil
        await apply(pending.action, confirmed: true, token: pending.token)
    }

    func receiveDeferredPickUpdate(_ payload: BotJSON) {
        if receiveDeferredPickRefusal(payload) { return }
        guard let context else {
            if deferredPick != nil { heldConfirmation = payload }
            return
        }
        guard let option = deferredPick?.model, payload["status"].text == "confirmation_required",
              let token = payload["confirm"].text, !token.isEmpty, payload["payload"]["model"].text == option.id
        else { return }
        deferredPick = nil
        confirmation = Confirmation(action: Action(context: context, change: .model(option), expectedModel: catalog.active),
                                    message: payload["confirm_message"].text ?? String(localized: "Confirm this model change?"),
                                    token: token)
    }

    func apply(_ action: Action, confirmed: Bool = false, token: String? = nil) async {
        guard action.context == context, let wire, allowed(action.change), !consumed.contains(action.id) else { return }
        let (runtime, profile) = (action.context.runtime, action.context.profile)
        let call: HermesCall
        var canonicalModel: HermesCall.SessionMutation.Operation?
        switch action.change {
        case .model(let option):
            guard action.expectedModel == catalog.active else {
                errorMessage = BotFailure.stale.localizedDescription; return
            }
            guard let value = HermesModelCatalog.sessionModelValue(option) else {
                errorMessage = String(localized: "This model identifier cannot be safely sent to this host."); return
            }
            call = .configSet(sessionID: runtime, profile: profile, setting: .model(value: value, confirmExpensive: confirmed))
            if mutate != nil, let provider = option.providerID {
                canonicalModel = .model(id: option.id, provider: provider, confirm: token)
            }
        case .effort(let value):
            call = .configSet(sessionID: runtime, profile: profile, setting: .reasoning(value))
        case .fast(let enabled):
            call = .configSet(sessionID: runtime, profile: profile, setting: .fast(enabled))
        }
        errorMessage = nil; confirmation = nil; isApplying = true; activeAction = action.id
        readRevision += 1; isLoading = false
        var dispatched = false
        defer {
            if activeAction == action.id { isApplying = false; activeAction = nil; settleDeferredPick() }
        }
        do {
            let check: () throws -> Void = { [weak self] in
                guard let self, self.context == action.context, self.activeAction == action.id,
                      !Task.isCancelled else { throw BotFailure.stale }
                if case .configSet = call, self.catalog.active != action.expectedModel { throw BotFailure.stale }
                dispatched = true
                self.consumed.insert(action.id)
            }
            let result: BotJSON
            if let canonicalModel, let mutate { result = try await mutate(canonicalModel, check) }
            else { result = try await wire.call(call, validateDispatch: check) }
            guard context == action.context, activeAction == action.id, !Task.isCancelled else { return }
            readRevision += 1; isLoading = false
            if case .model = action.change { deferredPick = nil }
            switch action.change {
            case .model(let option) where canonicalModel != nil:
                if result["status"].text == "confirmation_required", let token = result["confirm"].text, !token.isEmpty {
                    consumed.remove(action.id)
                    confirmation = Confirmation(action: action, message: result["confirm_message"].text
                        ?? String(localized: "Confirm this model change?"), token: token)
                } else if result["operation"].text == "model" {
                    pendingModel = result["status"].text == "deferred" ? option : nil
                    deferredPick = pendingModel.map { ($0, action.expectedModel) }
                    await reload()
                    if result["status"] == .null { announce(option, for: action) }
                } else { throw BotSettingFailure.unknownOutcome }
            case .model(let option):
                guard result["key"].text == "model", result["scope"].text == "session",
                      result["value"].text != nil else { throw BotSettingFailure.unknownOutcome }
                if result["confirm_required"].flag == true {
                    consumed.remove(action.id)
                    confirmation = Confirmation(action: action, message: result["confirm_message"].text ?? result["warning"].text ?? String(localized: "Confirm this model change?"))
                } else if result["confirm_required"].flag == false {
                    pendingModel = result["deferred"].flag == true ? option : nil
                    deferredPick = pendingModel.map { ($0, action.expectedModel) }
                    await reload()
                    if result["deferred"].flag != true { announce(option, for: action) }
                } else { throw BotSettingFailure.unknownOutcome }
            case .effort(let value):
                guard result["key"].text == "reasoning", result["value"].text == value else { throw BotSettingFailure.unknownOutcome }
                effort = value
            case .fast(let enabled):
                guard result["key"].text == "fast", result["value"].text == (enabled ? "fast" : "normal") else { throw BotSettingFailure.unknownOutcome }
                fast = enabled
            }
        } catch {
            guard context == action.context, activeAction == action.id, !Task.isCancelled else { return }
            if isRefused(error) { refused.insert(call.method) }
            if error is HermesFenceRefusal {
                errorMessage = String(localized: "This chat changed on the server. Reopen it and try again.")
            } else if case BotSettingFailure.rejected = error { errorMessage = error.localizedDescription }
            else if !dispatched || isUnsupported(error) { errorMessage = error.localizedDescription }
            else { errorMessage = BotSettingFailure.unknownOutcome.localizedDescription }
        }
    }

    private func announce(_ option: ModelCatalogOption, for action: Action) {
        guard context == action.context, activeAction == action.id,
              catalog.active?.matchesSelection(modelID: option.id, providerID: option.providerID) == true else { return }
        onPickedModelActive?(option)
    }

    private func allowed(_ change: Change) -> Bool {
        switch change {
        case .model: return mayChangeModel
        case .effort(let value): return mayChangeEffort && HermesModelCatalog.effortLevels.contains(value)
        case .fast: return mayChangeFast
        }
    }
    private func isUnsupported(_ error: Error) -> Bool {
        if isRefused(error) || error as? BotFailure == .rejected(-32601) { return true }
        if case BotSettingFailure.rejected(-32601, _) = error { return true }
        return false
    }
    private func isRefused(_ error: Error) -> Bool {
        if case BotSettingFailure.rejected(403, _) = error { return true }
        return error as? BotFailure == .unsupported
    }
}
