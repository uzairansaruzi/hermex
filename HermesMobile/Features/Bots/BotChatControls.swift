import Foundation
import Observation

/// One conversation's controls. Every read, confirmation and socket write belongs
/// to one connection generation and runtime; disconnect invalidates them together.
@MainActor @Observable final class BotChatControls {
    struct Context: Equatable {
        let connectionID: UUID
        let profile: String
        let runtime: String
        let generation: Int
    }
    enum Change: Equatable {
        case model(ModelCatalogOption), effort(String), fast(Bool), workspace(String), control(BotSessionControl)
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
        var id: UUID { action.id }
    }

    private(set) var catalog = HermesModelCatalog(.null)
    private(set) var workspace: String?
    private(set) var effort: String?
    private(set) var fast: Bool?
    private(set) var usage = BotChatUsage(.null)
    private(set) var controls: [BotSessionControl] = []
    private(set) var pendingModel: ModelCatalogOption?
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
    private var lastContext: Context?
    private var idle = false
    private(set) var snapshotRevision = 0
    /// False for a Hermes session's composer (#1015), which reads only the model catalog:
    /// its goal and side work read `session.control` on their own (`HermesChatSideTasks`).
    private let readsSessionControl: Bool

    init(readsSessionControl: Bool = true) {
        self.readsSessionControl = readsSessionControl
    }

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
    var mayChangeWorkspace: Bool { context != nil && idle && !isApplying && !unavailable.contains("session.cwd.set") }
    var mayControl: Bool { context != nil && !isApplying && !unavailable.contains("session.control") }

    func connect(_ context: Context, wire: any BotTransport) async {
        disconnect()
        if lastContext?.connectionID != context.connectionID || lastContext?.profile != context.profile {
            pendingModel = nil; refused = []; errorMessage = nil
        }
        if lastContext?.runtime != context.runtime { pendingModel = nil }
        lastContext = context
        catalog = HermesModelCatalog(.null); controls = []
        workspace = nil; effort = nil; fast = nil; usage = BotChatUsage(.null); idle = false
        self.context = context; self.wire = wire
        await reload()
    }

    func disconnect() {
        if let activeAction, consumed.contains(activeAction) {
            errorMessage = BotSettingFailure.unknownOutcome.localizedDescription
        }
        context = nil; wire = nil
        readTask?.cancel(); readTask = nil; readAgain = false; readRevision += 1
        confirmation = nil; activeAction = nil; isApplying = false; isLoading = false
        consumed.removeAll()
    }

    func snapshot(_ info: BotJSON, idle: Bool) {
        self.idle = idle
        workspace = info["cwd"].text
        effort = info["reasoning_effort"].text
        fast = info["fast"].flag
        usage = BotChatUsage(info["usage"])
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
        var reads: [HermesCall] = [.modelOptions(sessionID: owner.runtime, profile: owner.profile)]
        if readsSessionControl { reads.append(.sessionControlRead(sessionID: owner.runtime, profile: owner.profile)) }
        for call in reads where !unavailable.contains(call.method) {
            do {
                let result = try await wire.call(call)
                guard context == owner, revision == readRevision, !Task.isCancelled else { return }
                if case .modelOptions = call {
                    guard result["providers"].list != nil else { throw BotFailure.unsupported }
                    catalog = HermesModelCatalog(result)
                    if let pendingModel, catalog.active?.matchesSelection(modelID: pendingModel.id, providerID: pendingModel.providerID) == true {
                        self.pendingModel = nil
                    }
                } else {
                    guard result["control"].fields != nil else { throw BotFailure.unsupported }
                    controls = BotSessionControl.read(result["control"])
                }
            } catch {
                guard context == owner, revision == readRevision, !Task.isCancelled else { return }
                // A -32601 needs nothing here: the connection has recorded it.
                if isRefused(error) { refused.insert(call.method) }
                else if !isUnsupported(error) { errorMessage = error.localizedDescription }
            }
        }
    }

    func prepare(_ change: Change) -> Action? {
        guard let context, allowed(change) else { return nil }
        return Action(context: context, change: change, expectedModel: catalog.active)
    }

    func cancelConfirmation() { confirmation = nil }
    func confirm() async {
        guard let pending = confirmation, allowed(pending.action.change) else { return }
        confirmation = nil
        await apply(pending.action, confirmed: true)
    }

    func apply(_ action: Action, confirmed: Bool = false) async {
        guard action.context == context, let wire, allowed(action.change), !consumed.contains(action.id) else { return }
        let (runtime, profile) = (action.context.runtime, action.context.profile)
        let call: HermesCall
        switch action.change {
        case .model(let option):
            guard action.expectedModel == catalog.active else {
                errorMessage = BotFailure.stale.localizedDescription; return
            }
            guard let value = HermesModelCatalog.sessionModelValue(option) else {
                errorMessage = String(localized: "This model identifier cannot be safely sent to this host."); return
            }
            call = .configSet(sessionID: runtime, profile: profile, setting: .model(value: value, confirmExpensive: confirmed))
        case .effort(let value):
            call = .configSet(sessionID: runtime, profile: profile, setting: .reasoning(value))
        case .fast(let enabled):
            call = .configSet(sessionID: runtime, profile: profile, setting: .fast(enabled))
        case .workspace(let path):
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            call = .sessionCwdSet(sessionID: runtime, profile: profile, cwd: path)
        case .control(let control):
            guard let name = control.action else { return }
            call = .sessionControl(sessionID: runtime, profile: profile, action: name)
        }
        errorMessage = nil; confirmation = nil; isApplying = true; activeAction = action.id
        // A read started before this write must not overwrite its authoritative response.
        readRevision += 1; snapshotRevision += 1; isLoading = false
        var dispatched = false
        defer { if activeAction == action.id { isApplying = false; activeAction = nil } }
        do {
            let result = try await wire.call(call, validateDispatch: { [weak self] in
                guard let self, self.context == action.context, self.activeAction == action.id,
                      !Task.isCancelled else { throw BotFailure.stale }
                if case .workspace = action.change, !self.idle { throw BotFailure.stale }
                if case .control(let control) = action.change, !self.controls.contains(control) { throw BotFailure.stale }
                if case .configSet = call, self.catalog.active != action.expectedModel { throw BotFailure.stale }
                dispatched = true
                self.consumed.insert(action.id)
            })
            guard context == action.context, activeAction == action.id, !Task.isCancelled else { return }
            readRevision += 1; snapshotRevision += 1; isLoading = false
            switch action.change {
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
            case .workspace:
                guard let cwd = result["cwd"].text, !cwd.isEmpty else { throw BotSettingFailure.unknownOutcome }
                workspace = cwd
            case .control:
                guard result["control"].fields != nil else { throw BotSettingFailure.unknownOutcome }
                controls = BotSessionControl.read(result["control"])
            }
        } catch {
            guard context == action.context, activeAction == action.id, !Task.isCancelled else { return }
            if isRefused(error) { refused.insert(call.method) }
            if case BotSettingFailure.rejected = error { errorMessage = error.localizedDescription }
            else if !dispatched || isUnsupported(error) { errorMessage = error.localizedDescription }
            else { errorMessage = BotSettingFailure.unknownOutcome.localizedDescription }
        }
    }

    private func allowed(_ change: Change) -> Bool {
        switch change {
        case .model: return mayChangeModel
        case .effort(let value): return mayChangeEffort && HermesModelCatalog.effortLevels.contains(value)
        case .fast: return mayChangeFast
        case .workspace: return mayChangeWorkspace
        case .control(let control): return mayControl && controls.contains(control) && control.action != nil
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
