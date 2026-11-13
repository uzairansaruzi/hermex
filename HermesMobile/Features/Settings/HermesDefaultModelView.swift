import Observation
import SwiftUI

/// The state behind a Hermes server's Default Model page (#1670): the Profile shown, its model as
/// the host reports it, and the models it can switch to. It starts on the Profile the Sessions side
/// opens new sessions in, and picking another Profile here never changes that pick.
///
/// Nothing is optimistic: the shown model changes only once the host applied the pick. An expensive
/// model the host wants confirmed writes nothing until the user continues. The host has no "unset",
/// so the way back is picking the earlier model again.
@MainActor @Observable final class HermesDefaultModel {
    enum State: Equatable { case loading, loaded, failed(String) }

    /// A pick the host asked to confirm, with its reason.
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let option: ModelCatalogOption
        let message: String
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    /// The Profile shown and written to, once the host has named its Profiles.
    private(set) var profile: String?
    /// The Profile's pinned model; nil when it pins none.
    private(set) var current: ModelCatalogOption?
    private(set) var modelGroups: [ModelCatalogGroup] = []
    /// The pick out at the host, for the picker's spinner.
    private(set) var saving: ModelCatalogOption?
    private(set) var saveError: String?
    private(set) var confirmation: Confirmation?

    private let server: URL
    private let connection: BotConnection
    private let preferences: UserDefaults
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    @ObservationIgnored private var wire: (any BotTransport)?
    /// Bumped by each read and by `close()`, so only the latest read or save applies.
    @ObservationIgnored private var serial = 0

    init(connection: BotConnection, server: URL, preferences: UserDefaults = .standard,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil) {
        self.connection = connection; self.server = server; self.preferences = preferences
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }
    }

    /// Reads the host's Profiles, keeping the shown one while the host still lists it and otherwise
    /// starting on the Sessions side's pick (`HermesProfilePreference.starting`), then that Profile.
    func load() async {
        serial += 1
        let owner = serial
        if case .failed = state { state = .loading }
        do {
            let start = try await HermesProfilePreference.starting(for: server, on: try await connectedWire(), in: preferences)
            guard owner == serial else { return }
            profiles = start.listed.contains(start.profile) ? start.listed : [start.profile] + start.listed
            await read(profile.flatMap { profiles.contains($0) ? $0 : nil } ?? start.profile, owner: owner)
        } catch {
            fail(error, owner: owner)
        }
    }

    /// Shows `name`'s model. The Sessions side's pick stays where it was.
    func select(_ name: String) async {
        guard name != profile else { return }
        serial += 1
        await read(name, owner: serial)
    }

    /// Pins `option` as the shown Profile's model. True once the host applied it; a model the host
    /// wants confirmed sets `confirmation` instead and writes nothing, until it is saved again
    /// `confirmed`.
    func save(_ option: ModelCatalogOption, confirmed: Bool = false) async -> Bool {
        guard let name = profile, let provider = option.providerID, saving == nil else { return false }
        let owner = serial
        saving = option; saveError = nil; confirmation = nil
        var changes = HermesCall.ProfileChanges(name: name)
        changes.model = HermesCall.Model(id: option.id, provider: provider)
        changes.confirmExpensiveModel = confirmed
        do {
            let reply = try await connectedWire().call(.profilesConfigure(changes))
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

    /// Leaves the Profile on its current model.
    func decline() { confirmation = nil }

    /// Ends this page's calls; the shared socket stays for the server's other screens.
    func close() {
        serial += 1
        wire?.close(); wire = nil
        saving = nil; confirmation = nil
    }

    /// The Profile's model, then its cached model list, shown at once; the providers' live lists
    /// replace the cached one when they answer.
    private func read(_ name: String, owner: Int) async {
        profile = name; current = nil; modelGroups = []; saving = nil; saveError = nil; confirmation = nil
        state = .loading
        do {
            let wire = try await connectedWire()
            let details = BotProfileDetails(try await wire.call(.profilesDescribe(name: name)), expectedName: name)
            let cached = try? await wire.call(.profileModelOptions(profile: name))
            guard owner == serial else { return }
            current = details.model
            modelGroups = cached.map { HermesModelCatalog($0).groups } ?? []
            state = .loaded
            guard let live = try? await wire.call(.profileModelOptions(profile: name, refresh: true)),
                  owner == serial else { return }
            modelGroups = HermesModelCatalog(live).groups
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

    /// A client the socket dropped is replaced on the next call.
    private func dropLostWire(_ error: Error) {
        guard let failure = error as? BotFailure, [.stale, .transport].contains(failure) else { return }
        wire?.close(); wire = nil
    }

    /// This page's client on the socket, connecting it first. A client another call connected
    /// meanwhile wins.
    private func connectedWire() async throws -> any BotTransport {
        if let wire { return wire }
        let client = makeWire(connection)
        client.onDisconnect = { [weak self, weak client] _ in
            guard let self, let client, self.wire === client else { return }
            self.wire = nil
        }
        try await client.connect()
        if let wire {
            client.close()
            return wire
        }
        wire = client
        return client
    }
}

/// A Hermes server's Default Model page (#1670), opened from its Settings page: one Profile's
/// model, the one new sessions in that Profile start on, with a menu of the host's other Profiles.
struct HermesDefaultModelView: View {
    @State private var model: HermesDefaultModel
    @State private var showsPicker = false
    /// Whether the pick out at the host came from the custom entry, whose button shows the spinner.
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
                        Text(verbatim: model.current?.displayName ?? "—")
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
            isSelectionDisabled: model.saving != nil,
            errorMessage: model.saveError,
            onSelect: { option in save(option) },
            onCommitCustom: { option in save(option, custom: true) }
        )
        // On the sheet, which stays up until the host applies the pick.
        .alert("Confirm this model change?", isPresented: Binding(
            get: { model.confirmation != nil }, set: { if !$0 { model.decline() } }
        ), presenting: model.confirmation) { confirmation in
            Button("Cancel", role: .cancel) { model.decline() }
            Button("Continue") { save(confirmation.option, confirmed: true) }
        } message: { confirmation in
            Text(verbatim: confirmation.message)
        }
    }

    /// Sends the pick, closing the picker once the host applied it.
    private func save(_ option: ModelCatalogOption, confirmed: Bool = false, custom: Bool = false) {
        // A confirmed resend is the same pick, from the same entry.
        if !confirmed { savingCustom = custom }
        Task { if await model.save(option, confirmed: confirmed) { showsPicker = false } }
    }
}
