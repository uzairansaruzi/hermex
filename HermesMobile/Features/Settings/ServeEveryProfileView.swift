import SwiftUI

@MainActor @Observable final class ServeEveryProfileModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case ready(HermesMigrationPlan)
        case working(Step)
        case served
        case unconfirmed
    }

    enum Step: Equatable { case removing, restarting, checking }

    private(set) var phase: Phase = .loading
    var keepers: [HermesDuplicateBot.ID: String] = [:]
    let profile: String?
    var onServed: (() -> Void)?

    private let client: HermesGatewayMigrationClient
    private let restartDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var work: Task<Void, Never>?
    private var unhandled: Set<HermesDuplicateBot.ID> = []

    init(client: HermesGatewayMigrationClient, profile: String?,
         restartDelays: [Duration] = [.seconds(2), .seconds(2), .seconds(3), .seconds(3), .seconds(5), .seconds(5),
                                      .seconds(10), .seconds(10), .seconds(10), .seconds(10), .seconds(10), .seconds(10)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.profile = profile
        self.restartDelays = restartDelays
        self.sleep = sleep
    }

    static let servedProfile = "default"

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

    func keeper(of bot: HermesDuplicateBot) -> String { keepers[bot.id] ?? bot.keeper }

    func loser(of bot: HermesDuplicateBot) -> String { keeper(of: bot) == bot.keeper ? bot.other : bot.keeper }

    func reload() async {
        phase = .loading
        await readPlan()
    }

    @discardableResult func removeDuplicates() -> Task<Void, Never>? {
        guard case .ready(let plan) = phase else { return nil }
        return run { [self] in
            phase = .working(.removing)
            do {
                for bot in plan.duplicateBots { try await client.remove(bot, from: loser(of: bot)) }
                let next = try await client.plan()
                guard !Task.isCancelled else { return }
                unhandled.formUnion(Set(plan.duplicateBots.map(\.id)).intersection(next.duplicateBots.map(\.id)))
                phase = .ready(next.unhandling(unhandled))
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult func migrate() -> Task<Void, Never>? {
        guard case .ready(let plan) = phase, !plan.isBlocked else { return nil }
        return run { [self] in
            phase = .working(.restarting)
            do { try await client.migrate() } catch let error as URLError where error.code != .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                return
            }
            let client = self.client
            let last = await HermesRestartWait.lastAnswer(after: restartDelays, sleep: sleep) {
                try? await client.plan()
            } isFinal: { $0.servesEveryProfile }
            guard !Task.isCancelled else { return }
            guard let last, last.servesEveryProfile else {
                phase = last.map { $0.isBlocked ? .ready($0) : .unconfirmed } ?? .unconfirmed
                return
            }
            await confirmServed()
        }
    }

    func leave() {
        work?.cancel()
        work = nil
    }

    private func readPlan() async {
        do {
            let plan = try await client.plan().unhandling(unhandled)
            guard !Task.isCancelled else { return }
            if plan.servesEveryProfile && !plan.isBlocked { await confirmServed() } else { phase = .ready(plan) }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func confirmServed() async {
        if let profile {
            phase = .working(.checking)
            let opens = await client.opens(profile: profile)
            guard !Task.isCancelled else { return }
            guard opens else { phase = .unconfirmed; return }
        }
        phase = .served
        onServed?()
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

struct ServeEveryProfileView: View {
    @State private var model: ServeEveryProfileModel
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingMigration = false
    @State private var recoveryFailure: NewChatWithContentError?
    @Environment(\.dismiss) private var dismiss
    private let server: URL

    init(connection: BotConnection, server: URL, profile: String?, onServed: (() -> Void)? = nil) {
        self.server = server
        let http = HermesConnections.shared.connection(for: connection, server: server)
        let model = ServeEveryProfileModel(client: HermesGatewayMigrationClient(http: http), profile: profile)
        model.onServed = {
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
                Text("Hermex can’t fix this from the phone. The agent on \(ServeEveryProfileModel.servedProfile) can explain it and propose commands for you to run on the host. Hermex asks it not to read secrets or restart the gateway. Then check again.")
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
