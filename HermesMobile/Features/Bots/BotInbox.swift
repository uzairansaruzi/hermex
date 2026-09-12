import Observation
import UIKit

/// The Bots inbox for one configured server: the roster, Desktop's pin and hidden
/// organization, device-local unread marks, and one live subscription that lasts
/// while the inbox is visible. `open()` owns the transport and `close()` ends it;
/// every late reply is dropped by the wire identity check, so a replaced or closed
/// connection never writes into the screen.
@MainActor @Observable final class BotInbox {
    enum Link: Equatable { case idle, connecting, live, disconnected }

    /// The roster split the way Desktop draws it: pinned first, the rest in server
    /// order, hidden bots apart and only when revealed or when a search names them.
    struct Rows: Equatable {
        var pinned: [BotProfile] = []
        var others: [BotProfile] = []
        var hidden: [BotProfile] = []
    }

    let server: URL
    private(set) var connection: BotConnection?
    private(set) var profiles: [BotProfile] = []
    private(set) var avatars: [String: UIImage] = [:]
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    /// Outcome of the last pin or hide write when it did not apply.
    private(set) var notice: String?
    /// Profiles with a pin or hide write in flight; their actions stay inert.
    private(set) var editing: Set<String> = []
    /// Session-only reveal of hidden bots, as in Desktop. Never persisted.
    var showsHidden = false
    /// Device-local watermarks for the current connection: the canonical
    /// `last_active` the user last saw for each Profile. Never leaves the phone.
    private(set) var seen: [String: Double] = [:]

    private var wire: (any BotTransport)?
    private var reloadTask: Task<Void, Never>?
    private var reloadWanted = false
    private var reloadSerial = 0
    private var returnedFrom: String?
    private let store: BotConnectionStore
    private let unread: BotUnreadStore
    private let avatarStore: BotAvatarStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    /// Minimum gap between event-driven roster reads; the host already floors
    /// `sessions.changed` at two seconds, this guards against a chattier one.
    private let reloadSpacing: Duration

    init(server: URL, store: BotConnectionStore? = nil, unread: BotUnreadStore = BotUnreadStore(),
         avatarStore: BotAvatarStore? = nil, reloadSpacing: Duration = .seconds(1),
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil) {
        self.server = server; self.store = store ?? BotConnectionStore(); self.unread = unread
        self.avatarStore = avatarStore ?? .shared; self.reloadSpacing = reloadSpacing
        self.makeWire = makeWire ?? { BotClient(connection: $0) }
    }

    var hiddenCount: Int { profiles.filter(\.hidden).count }

    func rows(matching search: String) -> Rows {
        let matching = profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        let shown = matching.filter { !$0.hidden }
        return Rows(pinned: shown.filter(\.pinned), others: shown.filter { !$0.pinned },
                    hidden: showsHidden || !search.isEmpty ? matching.filter(\.hidden) : [])
    }

    /// True when the canonical chat moved past what this device last showed.
    /// A row without a watermark reads as seen: the first roster load seeds it.
    func isUnread(_ profile: BotProfile) -> Bool {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, let mark = seen[profile.id] else { return false }
        return lastActive > mark
    }

    /// The user is entering this bot's chat: the row's activity is now seen.
    func markSeen(_ profile: BotProfile) {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, seen[profile.id] != lastActive else { return }
        seen[profile.id] = lastActive
        persistSeen()
    }

    /// The user came back from this bot's chat. Whatever the next roster read
    /// shows was on screen while they were there, so it is marked seen once and
    /// normal tracking resumes after that.
    func noteReturn(from profile: BotProfile) {
        markSeen(profile)
        returnedFrom = profile.id
    }

    /// Connects, reads the roster and avatars, and keeps the socket for live
    /// `sessions.changed` reloads. Also the pull-to-refresh and Reconnect path.
    func open() async {
        close()
        do {
            let saved = try store.load(server: server)
            if connection?.id != saved?.id { profiles = []; avatars = [:]; seen = [:] }
            connection = saved
            guard let saved else { link = .idle; return }
            if seen.isEmpty { seen = unread.load(connectionID: saved.id) }
            let client = makeWire(saved)
            wire = client; link = .connecting; errorMessage = nil; notice = nil
            client.onEvent = { [weak self] event in
                guard let self, self.wire === client, event["type"].text == "sessions.changed" else { return }
                self.noteChange()
            }
            client.onDisconnect = { [weak self] _ in
                guard let self, self.wire === client else { return }
                self.drop(client, message: String(localized: "Live updates stopped. Pull down to refresh."))
            }
            try await client.connect()
            guard wire === client, !Task.isCancelled else { return }
            guard await reload(client) else { return }
            link = .live
            await refreshAvatars(client)
        } catch {
            guard let client = wire, !Task.isCancelled else { return }
            drop(client, message: (error as? BotFailure ?? .transport).localizedDescription)
        }
    }

    func close() {
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        wire?.close(); wire = nil
        link = .idle
    }

    func mayEdit(_ profile: BotProfile) -> Bool { link == .live && !editing.contains(profile.id) }

    func setPinned(_ pinned: Bool, _ profile: BotProfile) async { await configure(profile, "pinned", .bool(pinned)) }
    func setHidden(_ hidden: Bool, _ profile: BotProfile) async { await configure(profile, "hidden", .bool(hidden)) }

    /// Writes one Desktop look field through `profiles.configure`, sending the whole
    /// `hermes-bots` object back so unrelated Desktop fields survive, under the look
    /// revision the row was read at. Nothing is shown as done until the host says
    /// it applied and the roster is re-read; a conflict means Desktop wrote in
    /// between, so the fresh roster is shown and the user decides whether to retry.
    private func configure(_ profile: BotProfile, _ field: String, _ value: BotJSON) async {
        guard mayEdit(profile), let client = wire else { return }
        editing.insert(profile.id); notice = nil
        defer { editing.remove(profile.id) }
        var look = profile.look
        look[field] = value
        do {
            let reply = try await client.call("profiles.configure", [
                "name": .string(profile.id),
                "ui_meta": .object(["hermes-bots": .object(look)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(profile.lookRevision ?? 0))])
            ])
            guard wire === client else { return }
            if reply["applied"]["ui_meta"].flag != true {
                notice = reply["applied"]["ui_meta_conflicts"] != .null
                    ? String(localized: "This bot changed in Hermes Desktop. The list was refreshed; try again.")
                    : String(localized: "Hermes did not save this change.")
            }
            if await reload(client) { await refreshAvatars(client) }
        } catch {
            guard wire === client else { return }
            notice = error as? BotFailure == .rejected(-32601)
                ? String(localized: "This Hermes version cannot organize bots from the phone.")
                : String(localized: "Hermes did not save this change.")
        }
    }

    /// Coalesces `sessions.changed` bursts: one reload in flight, at most one
    /// more queued, spaced by `reloadSpacing`. Avatars are not refreshed here
    /// because the event follows session activity, and a look change never moves it.
    private func noteChange() {
        reloadWanted = true
        guard reloadTask == nil, let client = wire else { return }
        reloadTask = Task { [weak self] in
            while let self, self.reloadWanted, self.wire === client, !Task.isCancelled {
                self.reloadWanted = false
                _ = await self.reload(client)
                guard self.wire === client, (try? await Task.sleep(for: self.reloadSpacing)) != nil else { break }
            }
            guard let self, self.wire === client else { return }
            self.reloadTask = nil
        }
    }

    /// One `profiles.list` on the live socket. Only the newest request's reply is
    /// applied, and only while `client` still owns the inbox.
    private func reload(_ client: any BotTransport) async -> Bool {
        reloadSerial += 1
        let serial = reloadSerial
        do {
            let roster = try await client.call("profiles.list", ["include_sessions": .bool(true)])
            guard wire === client, serial == reloadSerial else { return false }
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            var ids = Set<String>()
            profiles = rows.compactMap(BotProfile.init).filter { ids.insert($0.id).inserted }
            var changed = false
            for profile in profiles {
                guard let lastActive = profile.lastActive?.timeIntervalSince1970,
                      seen[profile.id] == nil || profile.id == returnedFrom else { continue }
                seen[profile.id] = lastActive; changed = true
            }
            returnedFrom = nil
            if changed { persistSeen() }
            return true
        } catch {
            guard wire === client, serial == reloadSerial else { return false }
            drop(client, message: (error as? BotFailure ?? .transport).localizedDescription)
            return false
        }
    }

    private func refreshAvatars(_ client: any BotTransport) async {
        guard let connection else { return }
        await avatarStore.refresh(profiles, connectionID: connection.id, using: client) {
            if wire === client { avatars = avatarStore.images(connectionID: connection.id) }
        }
    }

    private func drop(_ client: any BotTransport, message: String) {
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        client.close(); wire = nil
        link = .disconnected
        errorMessage = message
    }

    private func persistSeen() {
        guard let connection else { return }
        unread.save(seen, connectionID: connection.id)
    }
}

/// Device-local record of the canonical activity the user last saw per bot,
/// keyed by connection UUID so equal Profile names on two hosts never share a
/// mark. Plain timestamps, so `UserDefaults` rather than the Keychain; the
/// values never leave the phone and Desktop has no matching state to sync.
struct BotUnreadStore {
    var defaults: UserDefaults = .standard

    private func key(_ connectionID: UUID) -> String { "bot-inbox-seen." + connectionID.uuidString }

    func load(connectionID: UUID) -> [String: Double] {
        defaults.dictionary(forKey: key(connectionID)) as? [String: Double] ?? [:]
    }

    func save(_ seen: [String: Double], connectionID: UUID) {
        defaults.set(seen, forKey: key(connectionID))
    }

    func remove(connectionID: UUID) {
        defaults.removeObject(forKey: key(connectionID))
    }
}
