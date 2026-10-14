import Foundation

/// One webui chat a Move to Hermes scan listed (#1213), with what later steps need from the row.
struct MoveToHermesSourceChat: Codable, Equatable, Sendable {
    let id: String
    /// The webui Profile holding it; a legacy row without one is the root Profile, `default`.
    let profile: String
    var title: String?
    /// The webui's count, which may be stale; only the export shows a chat's real size.
    var messageCount: Int?
    var archived: Bool
    var pinned: Bool
    var workspace: String?

    init(id: String, profile: String, title: String? = nil, messageCount: Int? = nil,
         archived: Bool = false, pinned: Bool = false, workspace: String? = nil) {
        self.id = id
        self.profile = profile
        self.title = title
        self.messageCount = messageCount
        self.archived = archived
        self.pinned = pinned
        self.workspace = workspace
    }

    init(_ row: WebuiScanListing.Row) {
        self.init(id: row.sessionId, profile: row.profile ?? "default", title: row.title,
                  messageCount: row.messageCount, archived: row.archived ?? false,
                  pinned: row.pinned ?? false, workspace: row.workspace)
    }

    /// Whether the webui's count alone puts the chat past the host's per-session import limit.
    /// A chat under it can still be too large in bytes, which only its export shows.
    var exceedsMessageLimit: Bool { (messageCount ?? 0) > WebuiSessionTransfer.messagesPerSession }
}

/// Where a webui chat's id is in Hermes, matched exactly across every destination Profile.
/// Best-effort duplicate detection: another client can still import the id between a check and
/// a write.
enum MoveToHermesLocation: Codable, Equatable, Sendable {
    /// Every Profile answered and none has it.
    case missing
    case present(profile: String)
    /// Two or more Profiles have it, so neither copying nor routing can pick one.
    case ambiguous(profiles: [String])
    /// A read failed, timed out or was cancelled and no two Profiles matched. Never absent.
    case unknown
}

/// The page `BotTransport.sessionScanPage` reads (#1213): each listed row's ids and the host's
/// `total`. A compressed chain lists its tip with `_lineage_root_id`, and both ids exist in the
/// Profile. A reply without `sessions` is a failed read.
struct HermesScanPage: Decodable, Equatable {
    let ids: [String]
    let total: Int?

    init(ids: [String], total: Int?) {
        self.ids = ids
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case sessions, total }
    private enum RowKeys: String, CodingKey { case id, lineageRoot = "_lineage_root_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var rows = try c.nestedUnkeyedContainer(forKey: .sessions)
        var ids: [String] = []
        while !rows.isAtEnd {
            guard let row = try? rows.nestedContainer(keyedBy: RowKeys.self) else {
                _ = try? rows.decode(BotJSON.self)
                continue
            }
            for key in [RowKeys.id, .lineageRoot] {
                if let id = try? row.decodeIfPresent(String.self, forKey: key), !id.isEmpty { ids.append(id) }
            }
        }
        self.ids = ids
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }
}

/// How many requests a Move sends one server at once, and the counting it reports.
enum MoveToHermesRequests {
    /// At most this many requests in flight per server (#707's owner decision).
    static let perServer = 4

    /// `work` for every item, at most `perServer` at a time, answered in the items' order.
    /// Cancelling the caller cancels the work in flight; items not yet started still run, each
    /// seeing the cancellation at its first request.
    @MainActor
    static func map<Item, Result: Sendable>(_ items: [Item], _ work: @escaping @MainActor (Item) async -> Result) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var results: [Result?] = Array(repeating: nil, count: items.count)
            var next = 0
            func start() {
                let index = next
                let item = items[index]
                next += 1
                group.addTask { @MainActor in (index, await work(item)) }
            }
            while next < min(perServer, items.count) { start() }
            for await (index, result) in group {
                results[index] = result
                if next < items.count { start() }
            }
            return results.map { $0! }
        }
    }
}

/// Move to Hermes's scan (#1213): which webui chats Hermes already has, by exact id. It reads
/// the webui list once across Profiles and lists every destination Profile page by page, then
/// reads each id no listing showed in every Profile. It never switches the webui Profile and
/// never writes. Each server sees at most `MoveToHermesRequests.perServer` requests at once.
enum MoveToHermesScan {
    struct Entry: Codable, Equatable, Sendable {
        let chat: MoveToHermesSourceChat
        let location: MoveToHermesLocation
    }

    struct Result: Codable, Equatable, Sendable {
        var entries: [Entry]
        /// Set when the webui listed only this Profile (it ignored `all_profiles`): every other
        /// webui Profile went unscanned, which is not the same as empty.
        var onlyProfile: String?
        /// Chats the webui listed as streaming a reply (#1218): a Move waits for them.
        var running: [String] = []
    }

    /// Scans `webui` against `hermesProfiles` on `hermes`. `progress` gets the chats located so
    /// far out of all of them. Throws only when the webui list can't be read; any Hermes read
    /// that fails leaves its chats `.unknown`.
    @MainActor
    static func run(webui: APIClient, hermes: any BotTransport, hermesProfiles: [String],
                    progress: @escaping @MainActor (_ located: Int, _ total: Int) -> Void = { _, _ in }) async throws -> Result {
        let listing = try await webui.moveScanSessions()
        var seen = Set<String>()
        let chats = listing.sessions.map(MoveToHermesSourceChat.init).filter { seen.insert($0.id).inserted }
        progress(0, chats.count)
        let listed = await listedIDs(in: hermesProfiles, on: hermes)
        let locations = await locate(chats.map(\.id), in: hermesProfiles, listed: listed, on: hermes) { located in
            progress(located, chats.count)
        }
        return Result(entries: chats.map { Entry(chat: $0, location: locations[$0.id] ?? .unknown) },
                      onlyProfile: listing.allProfiles == true ? nil : listing.activeProfile,
                      running: listing.sessions.filter(\.isRunning).map(\.sessionId))
    }

    /// Every id each Profile lists, or nil for a Profile whose listing failed, so its ids are
    /// read one by one instead. Pages run until the host's `total`, never a short page: every
    /// page back-fills the Profile's pinned rows.
    @MainActor
    static func listedIDs(in profiles: [String], on hermes: any BotTransport) async -> [String: Set<String>?] {
        let lists = await MoveToHermesRequests.map(profiles) { profile -> Set<String>? in
            var ids = Set<String>()
            var offset = 0
            while true {
                guard let page = try? await hermes.sessionScanPage(profile: profile, offset: offset) else { return nil }
                ids.formUnion(page.ids)
                offset += HermesREST.sessionPageSize
                guard let total = page.total else { return page.ids.count < HermesREST.sessionPageSize ? ids : nil }
                if offset >= total { return ids }
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(profiles, lists))
    }

    /// Where each of `ids` is across `profiles`. A Profile `listed` showed an id has it. An id
    /// some listing showed is read only in Profiles whose listing failed; one none showed is read
    /// in every Profile. `listed` empty reads every id everywhere, as a recheck before an import does.
    @MainActor
    static func locate(_ ids: [String], in profiles: [String], listed: [String: Set<String>?] = [:],
                       on hermes: any BotTransport,
                       progress: @escaping @MainActor (Int) -> Void = { _ in }) async -> [String: MoveToHermesLocation] {
        let unlisted = profiles.filter { listed[$0].flatMap { $0 } == nil }
        var matches: [String: Set<String>] = [:]
        var checks: [(id: String, profile: String)] = []
        for id in ids {
            let found = Set(profiles.filter { listed[$0].flatMap { $0 }?.contains(id) == true })
            matches[id] = found
            // A listing leaves hidden rows out, so an id no listing showed is read everywhere.
            checks += (found.isEmpty ? profiles : unlisted).map { (id, $0) }
        }
        var failed = Set<String>()
        var remaining = Dictionary(grouping: checks, by: \.id).mapValues(\.count)
        var located = Set(ids).subtracting(remaining.keys).count
        progress(located)
        let answers = await MoveToHermesRequests.map(checks) { check -> Bool? in
            let answer = await has(check.id, in: check.profile, on: hermes)
            remaining[check.id, default: 1] -= 1
            if remaining[check.id] == 0 {
                located += 1
                progress(located)
            }
            return answer
        }
        for (check, answer) in zip(checks, answers) {
            switch answer {
            case true?: matches[check.id, default: []].insert(check.profile)
            case false?: break
            case nil: failed.insert(check.id)
            }
        }
        return ids.reduce(into: [:]) { locations, id in
            let found = profiles.filter { matches[id]?.contains($0) == true }
            if found.count > 1 {
                locations[id] = .ambiguous(profiles: found)
            } else if failed.contains(id) {
                locations[id] = .unknown
            } else {
                locations[id] = found.first.map { .present(profile: $0) } ?? .missing
            }
        }
    }

    /// Whether `profile` holds exactly `id`: a 404 is no, a failure nil. The host resolves an id
    /// it lacks to a unique prefix match, so a row answered under another id is no.
    @MainActor
    private static func has(_ id: String, in profile: String, on hermes: any BotTransport) async -> Bool? {
        guard !Task.isCancelled else { return nil }
        do {
            guard let row = try await hermes.sessionRow(key: id, profile: profile) else { return false }
            return row["id"].text == id
        } catch {
            return nil
        }
    }
}
