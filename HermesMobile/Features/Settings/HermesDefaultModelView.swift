import Observation
import SwiftUI

@MainActor @Observable final class HermesDefaultModel {
    enum State: Equatable { case loading, loaded, failed(String) }

    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let option: ModelCatalogOption
        let message: String
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    private(set) var profile: String?
    private(set) var current: ModelCatalogOption?
    private(set) var modelGroups: [ModelCatalogGroup] = []
    private(set) var saving: ModelCatalogOption?
    private(set) var saveError: String?
    private(set) var confirmation: Confirmation?

    private let server: URL
    private let connection: BotConnection
    private let preferences: UserDefaults
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    @ObservationIgnored private var wire: (client: any BotTransport, ready: Task<Void, Error>)?
    @ObservationIgnored private(set) var serial = 0

    init(connection: BotConnection, server: URL, preferences: UserDefaults = .standard,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil) {
        self.connection = connection; self.server = server; self.preferences = preferences
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }
    }

    func load() async {
        serial += 1
        let owner = serial
        state = .loading
        do {
            let start = try await HermesProfilePreference.starting(for: server, on: try await connectedWire(), in: preferences)
            guard owner == serial else { return }
            profiles = start.listed.contains(start.profile) ? start.listed : [start.profile] + start.listed
            await read(profile.flatMap { profiles.contains($0) ? $0 : nil } ?? start.profile, owner: owner)
        } catch {
            fail(error, owner: owner)
        }
    }

    func select(_ name: String) async {
        guard name != profile else { return }
        serial += 1
        await read(name, owner: serial)
    }

    func save(_ option: ModelCatalogOption, owner: Int, confirmed: Bool = false) async -> Bool {
        guard owner == serial, state == .loaded, let name = profile, let provider = option.providerID,
              saving == nil else { return false }
        saving = option; saveError = nil; confirmation = nil
        var changes = HermesCall.ProfileChanges(name: name)
        changes.model = HermesCall.Model(id: option.id, provider: provider)
        changes.confirmExpensiveModel = confirmed
        do {
            let reply = try await connectedWire().call(.profilesConfigure(changes), validateDispatch: validate(owner))
            guard owner == serial else { return false }
            saving = nil
            if reply["applied"]["model"].flag == true {
                current = option
                return true
            } else if reply["confirm_required"].flag == true {
                confirmation = Confirmation(option: option, message: reply["confirm_message"].text
                                            ?? String(localized: "Confirm this model change?"))
            } else {
                saveError = String(localized: "The server did not confirm the change.")
            }
        } catch {
            guard owner == serial else { return false }
            saving = nil
            dropLostWire(error)
            saveError = error.localizedDescription
        }
        return false
    }

    func decline() { confirmation = nil }

    var holdsConnection: Bool { wire != nil }

    func close() {
        serial += 1
        wire?.client.close(); wire = nil
        saving = nil; confirmation = nil
    }

    private func read(_ name: String, owner: Int) async {
        profile = name; current = nil; modelGroups = []; saving = nil; saveError = nil; confirmation = nil
        state = .loading
        do {
            let wire = try await connectedWire()
            let details = BotProfileDetails(try await wire.call(.profilesDescribe(name: name)), expectedName: name)
            let cached = try? await wire.call(.profileModelOptions(profile: name))
            guard owner == serial else { return }
            current = details.model
            if let cached {
                modelGroups = HermesModelCatalog(cached).groups
                state = .loaded
            }
            let refresh = HermesCall.profileModelOptions(profile: name, refresh: true)
            guard let live = cached == nil ? try await wire.call(refresh) : try? await wire.call(refresh),
                  owner == serial else { return }
            modelGroups = HermesModelCatalog(live).groups
            state = .loaded
        } catch {
            fail(error, owner: owner)
        }
    }

    private func fail(_ error: Error, owner: Int) {
        guard owner == serial, !(error is CancellationError) else { return }
        dropLostWire(error)
        state = .failed(error is URLError ? BotConnectionAdvice.message(for: error, address: connection.address)
                                          : error.localizedDescription)
    }

    private func dropLostWire(_ error: Error) {
        guard let failure = error as? BotFailure, [.stale, .transport].contains(failure) else { return }
        wire?.client.close(); wire = nil
    }

    private func validate(_ owner: Int) -> () throws -> Void {
        { [weak self] in guard self?.serial == owner else { throw BotFailure.stale } }
    }

    private func connectedWire() async throws -> any BotTransport {
        let wire = self.wire ?? openWire()
        do {
            try await wire.ready.value
        } catch {
            if self.wire?.client === wire.client { self.wire = nil }
            wire.client.close()
            throw error
        }
        guard self.wire?.client === wire.client else {
            wire.client.close()
            throw BotFailure.stale
        }
        return wire.client
    }

    private func openWire() -> (client: any BotTransport, ready: Task<Void, Error>) {
        let client = makeWire(connection)
        client.onDisconnect = { [weak self, weak client] _ in
            guard let self, let client, self.wire?.client === client else { return }
            self.wire = nil
        }
        let wire = (client: client, ready: Task { try await client.connect() })
        self.wire = wire
        return wire
    }
}

struct HermesDefaultModelView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: HermesDefaultModel
    @State private var showsPicker = false
    @State private var savingCustom = false

    init(connection: BotConnection, server: URL) {
        _model = State(initialValue: HermesDefaultModel(connection: connection, server: server))
    }

    var body: some View {
        AppList {
            if let profile = model.profile {
                ServerProfileRow(profiles: model.profiles, selection: profile) { name in
                    Task { await model.select(name) }
                }
            }
            content
        }
        .settingsPage(String(localized: "Default Model"))
        .task { await model.load() }
        .refreshable { await model.load() }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                model.close()
            } else if scenePhase == .active, !model.holdsConnection {
                Task { await model.load() }
            }
        }
        .sheet(isPresented: $showsPicker) { picker }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading models...")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Models", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            Section {
                Button {
                    showsPicker = true
                } label: {
                    LabeledContent {
                        Text(verbatim: model.current.map { ModelDisplayNames.displayLabel(for: $0.id, displayName: $0.displayName) } ?? "—")
                    } label: {
                        SettingsLabel(title: String(localized: "Default Model"), systemImage: "cpu",
                                      note: model.current?.providerID)
                    }
                }
                .foregroundStyle(.appPrimary)
                .accessibilityHint("Opens the default model picker.")
            } appFooter: {
                Text("New sessions in this Profile start on this model.")
            }
        }
    }

    private var picker: some View {
        ModelPickerSheet(
            configuration: .hermesProfileDefault,
            modelGroups: model.modelGroups,
            selectedModelID: model.current?.id,
            selectedModelProviderID: model.current?.providerID,
            isSelected: { option in
                let shown = model.saving ?? model.current
                return shown?.matchesSelection(modelID: option.id, providerID: option.providerID) == true
            },
            inFlightKey: savingCustom ? nil : model.saving?.favoriteKey,
            isCommittingCustom: savingCustom && model.saving != nil,
            isSelectionDisabled: model.saving != nil || model.state != .loaded,
            errorMessage: model.saveError,
            onSelect: { option in save(option) },
            onCommitCustom: { option in save(option, custom: true) }
        )
        .alert("Confirm this model change?", isPresented: Binding(
            get: { model.confirmation != nil }, set: { if !$0 { model.decline() } }
        ), presenting: model.confirmation) { confirmation in
            Button("Cancel", role: .cancel) { model.decline() }
            Button("Continue") { save(confirmation.option, confirmed: true) }
        } message: { confirmation in
            Text(verbatim: confirmation.message)
        }
    }

    private func save(_ option: ModelCatalogOption, confirmed: Bool = false, custom: Bool = false) {
        if !confirmed { savingCustom = custom }
        let owner = model.serial
        Task { if await model.save(option, owner: owner, confirmed: confirmed) { showsPicker = false } }
    }
}
