import SwiftUI

/// The guided fix for a Webapp that serves only one Profile (#1611): reads the host's preflight,
/// removes a duplicate bot credential from the Profile the user says shouldn't keep it, then
/// starts the migration after one confirmation, waits for the restarted gateway, and checks that
/// `profile`'s chats open. A blocker it can't remove gets a recovery chat with the agent instead.
/// The host owns every step; this owns only the screen's state.
@MainActor @Observable final class ServeEveryProfileModel {
    enum Phase: Equatable {
        case loading
        /// A read or write failed; Try Again reads the plan again.
        case failed(String)
        /// The preflight, blocked or clear.
        case ready(HermesMigrationPlan)
        case working(Step)
        /// The gateway serves every Profile, and `profile` opens.
        case served
        /// The wait ran out before the gateway served every Profile, or `profile` still didn't open.
        case unconfirmed
    }

    enum Step: Equatable { case removing, restarting, checking }

    private(set) var phase: Phase = .loading
    /// Per duplicate bot, the Profile that keeps it; the one that answers today until the user picks.
    var keepers: [HermesDuplicateBot.ID: String] = [:]
    /// The Profile whose chats couldn't open, checked once the gateway is back; nil from Settings.
    let profile: String?
    /// Called once, when the gateway serves every Profile.
    var onServed: (() -> Void)?

    private let client: HermesGatewayMigrationClient
    private let restartDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var work: Task<Void, Never>?

    init(client: HermesGatewayMigrationClient, profile: String?,
         restartDelays: [Duration] = [.seconds(2), .seconds(2), .seconds(3), .seconds(3), .seconds(5), .seconds(5),
                                      .seconds(10), .seconds(10), .seconds(10), .seconds(10), .seconds(10), .seconds(10)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.profile = profile
        self.restartDelays = restartDelays
        self.sleep = sleep
    }

    /// The Profile a gateway serving only one serves, where the recovery chat opens: the host's
    /// standalone gateway is the default root's, and records that it serves nobody else.
    static let servedProfile = "default"

    /// Opens a new chat on `server`'s served Profile, never New Session's, which may be one the
    /// Webapp doesn't serve. Its text names the unserved Profile and `blockers` in the host's
    /// words, and asks the agent to explain the migration's dry run and propose commands, under
    /// the triage playbook's guardrails. Nothing is sent until the user does.
    func openRecoveryChat(blockers: [String], server: URL, inbox: URL? = HermesShareDraft.containerURL()) throws {
        let who = profile.map { "the \($0) Profile's chats" } ?? "chats on every Profile but \(Self.servedProfile)"
        let prompt = """
        Hermex, the iPhone app I use to reach you, can't open \(who) on this host's Webapp: its gateway \
        serves only one Profile. The host says:

        \(blockers.joined(separator: "\n\n"))

        Explain what blocks it and how to make one gateway serve every Profile. You can run \
        `hermes gateway migrate --multiplex --dry-run`, which changes nothing, and walk me through its \
        output. Then propose each command or config change for me to run, and explain it. Don't read \
        `.env` or other credential files, and don't restart the gateway or change config yourself: \
        restarting it ends this chat.
        """
        try AppIntentRouter.shared.openNewChat(prefilling: prompt, server: server, profile: Self.servedProfile,
                                               origin: .troubleshooting, inbox: inbox)
    }

    /// The Profile that keeps `bot`.
    func keeper(of bot: HermesDuplicateBot) -> String { keepers[bot.id] ?? bot.keeper }

    /// The Profile `bot`'s credential is removed from: whichever of its two doesn't keep it.
    func loser(of bot: HermesDuplicateBot) -> String { keeper(of: bot) == bot.keeper ? bot.other : bot.keeper }

    func reload() async {
        phase = .loading
        await readPlan()
    }

    /// Removes each duplicate bot's credential from the Profile that doesn't keep it, then reads
    /// the plan again. A duplicate the host still reports could not be removed from here. Returns
    /// the work, which `leave` cancels.
    @discardableResult func removeDuplicates() -> Task<Void, Never>? {
        guard case .ready(let plan) = phase else { return nil }
        return run { [self] in
            phase = .working(.removing)
            do {
                for bot in plan.duplicateBots { try await client.remove(bot, from: loser(of: bot)) }
                let next = try await client.plan()
                guard !Task.isCancelled else { return }
                if next.duplicateBots.contains(where: { bot in plan.duplicateBots.contains { $0.id == bot.id } }) {
                    phase = .failed(String(localized: "The host still reports a duplicate bot token, so it may be set somewhere Hermex can’t change. Remove it on the host, then try again."))
                } else {
                    phase = .ready(next)
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Starts the migration, then waits for the restarted gateway to serve every Profile. Returns
    /// the work, which `leave` cancels.
    @discardableResult func migrate() -> Task<Void, Never>? {
        guard case .ready(let plan) = phase, !plan.isBlocked else { return nil }
        return run { [self] in
            phase = .working(.restarting)
            do { try await client.migrate() } catch let error as URLError where error.code != .cancelled {
                // A request the restart dropped started the migration as surely as an answer.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                return
            }
            let client = self.client
            let last = await HermesRestartWait.lastAnswer(after: restartDelays, sleep: sleep) {
                try? await client.plan()
            } isFinal: { $0.alreadyMultiplexed }
            guard !Task.isCancelled else { return }
            guard let last, last.alreadyMultiplexed else {
                // A migration the host refused leaves its blockers in the plan.
                phase = last.map { $0.isBlocked ? .ready($0) : .unconfirmed } ?? .unconfirmed
                return
            }
            if let profile {
                phase = .working(.checking)
                let opens = await client.opens(profile: profile)
                guard !Task.isCancelled else { return }
                guard opens else { phase = .unconfirmed; return }
            }
            phase = .served
            onServed?()
        }
    }

    /// Stops waiting when the screen goes; the host carries on with whatever it started.
    func leave() {
        work?.cancel()
        work = nil
    }

    private func readPlan() async {
        do {
            let plan = try await client.plan()
            guard !Task.isCancelled else { return }
            phase = plan.alreadyMultiplexed && !plan.isBlocked ? .served : .ready(plan)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard work == nil else { return nil }
        let task = Task { [weak self] in
            await body()
            self?.work = nil
        }
        work = task
        return task
    }
}

/// "Serve Every Profile": the screen for `ServeEveryProfileModel`, from a chat whose Profile the
/// Webapp doesn't serve or from the server's Settings page.
struct ServeEveryProfileView: View {
    @State private var model: ServeEveryProfileModel
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingMigration = false
    /// Why the recovery chat couldn't queue its text; nothing was queued.
    @State private var recoveryFailure: NewChatWithContentError?
    @Environment(\.dismiss) private var dismiss
    private let server: URL

    init(connection: BotConnection, server: URL, profile: String?, onServed: (() -> Void)? = nil) {
        self.server = server
        let http = HermesConnections.shared.connection(for: connection, server: server)
        let model = ServeEveryProfileModel(client: HermesGatewayMigrationClient(http: http), profile: profile)
        model.onServed = {
            // Every open chat reattaches to the restarted gateway.
            HermesConnections.shared.reconnectGateway(server: server)
            onServed?()
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        AppList {
            switch model.phase {
            case .loading:
                Section { Text("Reading the host’s plan…").foregroundStyle(.secondary) }
            case .failed(let message):
                Section {
                    Text(message)
                    Button("Try Again") { Task { await model.reload() } }
                }
            case .ready(let plan):
                planSections(plan)
            case .working(let step):
                progressSection(step)
            case .served:
                Section {
                    Label(model.profile.map { String(localized: "\($0) opens on this Webapp.") }
                          ?? String(localized: "This Webapp serves every Profile."),
                          systemImage: "checkmark.circle.fill")
                }
            case .unconfirmed:
                Section {
                    Text(model.profile.map { String(localized: "\($0) still doesn’t open here. The gateway may still be restarting.") }
                         ?? String(localized: "The gateway doesn’t serve every Profile yet. It may still be restarting."))
                    Button("Check Again") { Task { await model.reload() } }
                }
            }
        }
        .settingsPage(String(localized: "Serve Every Profile"))
        .task { await model.reload() }
        .onDisappear { model.leave() }
        .confirmationDialog(removalTitle, isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button(removalTitle, role: .destructive) { model.removeDuplicates() }
        } message: {
            Text("The tokens stay on the host in the Profiles that keep them. Hermex never reads their values.")
        }
        .alert("Restart the gateway?", isPresented: $isConfirmingMigration) {
            Button("Cancel", role: .cancel) {}
            Button("Restart and Serve Every Profile", role: .destructive) { model.migrate() }
        } message: {
            Text("Running work on every Profile stops, and bots go quiet until the gateway is back. Hermex reconnects when it is.")
        }
        .alert(String(localized: "Troubleshooting Can’t Open"), isPresented: Binding(
            get: { recoveryFailure != nil }, set: { if !$0 { recoveryFailure = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            if recoveryFailure == .tooManyWaiting {
                Text("10 texts are already waiting to open. Open or discard them in Sessions, then try again.")
            } else {
                Text("Hermex couldn’t save the text. Try again.")
            }
        }
    }

    private var removalTitle: String { String(localized: "Remove Duplicate Tokens") }

    @ViewBuilder
    private func planSections(_ plan: HermesMigrationPlan) -> some View {
        ForEach(plan.duplicateBots) { bot in
            Section {
                Picker(String(localized: "Keeps the bot"), selection: Binding {
                    model.keeper(of: bot)
                } set: { model.keepers[bot.id] = $0 }) {
                    Text(bot.keeper).tag(bot.keeper)
                    Text(bot.other).tag(bot.other)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("\(bot.platformName) bot")
            } footer: {
                Text("\(bot.keeper) answers on \(bot.platformName) today. Hermex removes \(bot.keys.formatted(.list(type: .and))) from \(model.loser(of: bot)).")
            }
        }
        if !plan.duplicateBots.isEmpty {
            Section {
                Button(removalTitle) { isConfirmingRemoval = true }
            } footer: {
                Text("To keep both bots, give the other Profile its own token later in API Keys.")
            }
        }
        if !plan.otherBlockers.isEmpty {
            Section {
                ForEach(plan.otherBlockers, id: \.self) { blocker in
                    Label { Text(blocker).font(.footnote) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Button("Ask the Agent on \(ServeEveryProfileModel.servedProfile)") {
                    do {
                        try model.openRecoveryChat(blockers: plan.otherBlockers, server: server)
                        dismiss()
                    } catch {
                        recoveryFailure = error as? NewChatWithContentError ?? .storage
                    }
                }
            } header: {
                Text("What blocks it")
            } footer: {
                Text("Hermex can’t fix this from the phone. The agent on \(ServeEveryProfileModel.servedProfile) can explain it and propose commands for you to run on the host; it won’t read secrets or restart the gateway. Then check again.")
            }
        }
        if !plan.isBlocked {
            Section {
                Label("Nothing blocks it", systemImage: "checkmark.circle.fill")
            }
            Section {
                Text("The gateway restarts. Running work on every Profile stops.")
                Text("Bots reconnect once it’s back.")
                ForEach(plan.movedListeners, id: \.self) { Text($0).font(.footnote) }
            } header: {
                Text("Before you start")
            }
            Section {
                Button("Serve Every Profile…") { isConfirmingMigration = true }
            }
        }
    }

    private func progressSection(_ step: ServeEveryProfileModel.Step) -> some View {
        Section {
            switch step {
            case .removing: Text("Removing duplicate tokens…")
            case .restarting: Text("Restarting the gateway…")
            case .checking: Text("Checking \(model.profile ?? "")…")
            }
        }
    }
}
