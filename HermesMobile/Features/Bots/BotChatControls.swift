import Foundation
import Observation

/// One Hermes chat's model, effort and Fast controls (`HermesChatSettings`). Every read,
/// confirmation and socket write belongs to one connection generation and runtime;
/// disconnect invalidates them together. On a canonical host (#1604) the model goes out as the
/// session's fenced `model` edit (`mutate`), and a confirmation resends the host's own token.
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
        /// A canonical host's token for exactly this selection; nil on the dashboard, which takes
        /// `confirm_expensive_model`.
        var token: String? = nil
        var id: UUID { action.id }
    }

    /// Sends one fenced edit of the session, checked at the write; a canonical host's model goes this way.
    typealias Mutate = (HermesCall.SessionMutation.Operation, @escaping () throws -> Void) async throws -> BotJSON

    private(set) var catalog = HermesModelCatalog(.null)
    private(set) var effort: String?
    private(set) var fast: Bool?
    private(set) var pendingModel: ModelCatalogOption?
    /// A canonical pick the host deferred to the running response's end, kept apart from
    /// `pendingModel` (a display state `session.info` clears) until the host asks to confirm it.
    private var deferredModel: ModelCatalogOption?
    private(set) var confirmation: Confirmation?
    private(set) var errorMessage: String?
    private(set) var isApplying = false
    private(set) var isLoading = false
    private(set) var context: Context?
    /// Methods this chat stopped calling after a 403 or an unusable reply. A method the
    /// host lacks (-32601) is the connection's to remember, for every chat on it.
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
    /// Methods this chat won't call: its own refusals and the connection's missing methods.
    private var unavailable: Set<String> { refused.union(wire?.unavailableMethods ?? []) }
    var mayChangeEffort: Bool { mayChangeModel && supportsEffort }
    var mayChangeFast: Bool { mayChangeModel && showsFast }

    var mayChangeModel: Bool { context != nil && !isApplying && !isLoading && !unavailable.contains("model.options") && !unavailable.contains("config.set") && catalog.active != nil }

    /// `mutate` is set on a canonical host, whose model is a session edit rather than `config.set`.
    func connect(_ context: Context, wire: any BotTransport, mutate: Mutate? = nil) async {
        disconnect()
        if lastContext?.connectionID != context.connectionID || lastContext?.profile != context.profile {
            pendingModel = nil; refused = []; errorMessage = nil
        }
        if lastContext?.runtime != context.runtime { pendingModel = nil; deferredModel = nil }
        lastContext = context
        catalog = HermesModelCatalog(.null); effort = nil; fast = nil
        self.context = context; self.wire = wire; self.mutate = mutate
        await reload()
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

    /// A `session.info`'s effort and Fast mode.
    func snapshot(_ info: BotJSON) {
        effort = info["reasoning_effort"].text
        fast = info["fast"].flag
        if let pendingModel, let reported = info["model"].text, reported != pendingModel.id {
            // Desktop may replace/cancel the queued choice, or the next turn may
            // resolve an alias to a canonical model. Do not keep an obsolete badge.
            self.pendingModel = nil
        }
        // `info.model` can be the queued choice. Only model.options reads the live
        // agent's model/provider; never use the display mirror for the active tick.
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
            if !Task.isCancelled { self.readTask = nil }
        }
    }

    func reload() async {
        guard let owner = context, let wire else { return }
        readRevision += 1
        let revision = readRevision
        isLoading = true
        defer { if context == owner && revision == readRevision { isLoading = false } }
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
            // A -32601 needs nothing here: the connection has recorded it. A lost connection is
            // the conversation's to report, and its reattach reads the catalog again.
            if isRefused(error) { refused.insert(call.method) }
            else if !isUnsupported(error), error as? BotFailure != .transport { errorMessage = error.localizedDescription }
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

    /// Resends `pending`'s pick confirmed, with its token on a canonical host. The sheet captures
    /// `pending` before dismissing, which clears `confirmation`.
    func confirm(_ pending: Confirmation) async {
        guard allowed(pending.action.change) else { return }
        confirmation = nil
        await apply(pending.action, confirmed: true, token: pending.token)
    }

    /// A canonical host asked, at the end of the running response, to confirm the pick it had
    /// deferred (`session.updated` with a `confirmation_required` model edit, #1604): the sheet
    /// asks for it as it would have at once, its token kept for the confirmed resend.
    func receiveDeferredConfirmation(_ payload: BotJSON) {
        // The event is the edit's own answer plus `payload`, the selection it deferred.
        guard let context, let option = deferredModel, payload["status"].text == "confirmation_required",
              let token = payload["confirm"].text, !token.isEmpty, payload["payload"]["model"].text == option.id
        else { return }
        deferredModel = nil
        confirmation = Confirmation(action: Action(context: context, change: .model(option), expectedModel: catalog.active),
                                    message: payload["confirm_message"].text ?? String(localized: "Confirm this model change?"),
                                    token: token)
    }

    /// `token` is a canonical host's confirmation token for this exact selection, resent once.
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
        // A read started before this write must not overwrite its authoritative response.
        readRevision += 1; isLoading = false
        var dispatched = false
        defer { if activeAction == action.id { isApplying = false; activeAction = nil } }
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
            switch action.change {
            case .model(let option) where canonicalModel != nil:
                // Nothing applied until the confirmed resend carries this token; a token another
                // change made stale is answered with a fresh one, asked again.
                if result["status"].text == "confirmation_required", let token = result["confirm"].text, !token.isEmpty {
                    consumed.remove(action.id)
                    confirmation = Confirmation(action: action, message: result["confirm_message"].text
                        ?? String(localized: "Confirm this model change?"), token: token)
                } else if result["operation"].text == "model" {
                    pendingModel = result["status"].text == "deferred" ? option : nil
                    deferredModel = pendingModel
                    await reload()
                } else { throw BotSettingFailure.unknownOutcome }
            case .model(let option):
                guard result["key"].text == "model", result["scope"].text == "session",
                      result["value"].text != nil else { throw BotSettingFailure.unknownOutcome }
                if result["confirm_required"].flag == true {
                    consumed.remove(action.id)
                    confirmation = Confirmation(action: action, message: result["confirm_message"].text ?? result["warning"].text ?? String(localized: "Confirm this model change?"))
                } else if result["confirm_required"].flag == false {
                    pendingModel = result["deferred"].flag == true ? option : nil
                    await reload()
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
                // The session changed first; nothing applied, and the next pick carries its new fences.
                errorMessage = String(localized: "This chat changed on the server. Reopen it and try again.")
            } else if case BotSettingFailure.rejected = error { errorMessage = error.localizedDescription }
            else if !dispatched || isUnsupported(error) { errorMessage = error.localizedDescription }
            else { errorMessage = BotSettingFailure.unknownOutcome.localizedDescription }
        }
    }

    private func allowed(_ change: Change) -> Bool {
        switch change {
        case .model: return mayChangeModel
        case .effort(let value): return mayChangeEffort && HermesModelCatalog.effortLevels.contains(value)
        case .fast: return mayChangeFast
        }
    }
    /// The host can't do this here: it refused (`isRefused`) or lacks the method (-32601).
    private func isUnsupported(_ error: Error) -> Bool {
        if isRefused(error) || error as? BotFailure == .rejected(-32601) { return true }
        if case BotSettingFailure.rejected(-32601, _) = error { return true }
        return false
    }
    /// A 403 or an unusable reply, which turns the method off for this chat alone.
    private func isRefused(_ error: Error) -> Bool {
        if case BotSettingFailure.rejected(403, _) = error { return true }
        return error as? BotFailure == .unsupported
    }
}
