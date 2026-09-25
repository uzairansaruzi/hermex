import Foundation

/// Room identity never borrows a display name or a hidden member session ID.
struct BotRoomKey: Hashable, Identifiable {
    let server: URL
    let connectionID: UUID
    let roomID: String
    var id: Self { self }
}

struct BotRoomCapabilities: Equatable {
    let enabled: Bool
    let authority: String?
    let pageLimit: Int
    let methods: Set<String>
    init(_ value: BotJSON) {
        let methods = Set(value["methods"].list?.compactMap(\.text) ?? [])
        self.methods = methods
        enabled = value["driver"].flag == true && Set(["groups.list", "groups.state", "groups.log"]).isSubset(of: methods)
        authority = value["authority_gateway_id"].text
        pageLimit = min(200, max(1, value["max_log_limit"].integer ?? 200))
    }
}

struct BotGroupRoom: Hashable {
    struct Member: Hashable, Identifiable {
        let id: String
        let profile: String?
        let displayName: String?
        let handle: String?
        var name: String { displayName ?? handle ?? profile ?? id }
        init?(_ value: BotJSON) {
            guard let id = value["member_id"].text else { return nil }
            self.id = id; profile = value["profile"].text
            displayName = value["display_name"].text; handle = value["handle"].text
        }
    }
    let id: String
    let name: String
    let members: [Member]
    let updatedAt: Date?
    let latestSeq: Int
    let authority: String?
    let epoch: Int?
    let disbanded: Bool
    init?(_ value: BotJSON) {
        guard let id = value["room_id"].text, BotRoomRPC.validID(id) else { return nil }
        self.id = id; name = value["name"].text ?? id
        members = value["members"].list?.compactMap(Member.init) ?? []
        updatedAt = value["updated_at"].number.map(Date.init(timeIntervalSince1970:))
        latestSeq = max(0, value["latest_seq"].integer ?? 0)
        authority = value["authority_gateway_id"].text; epoch = value["authority_epoch"].integer
        disbanded = value["disbanded_at"] != .null
    }
    func isForeign(to authority: String?) -> Bool {
        guard let authority, let owner = self.authority else { return false }
        return owner != authority
    }
}

struct BotRoomStatus: Equatable {
    let working: Bool
    let blocked: Bool
    let stopping: Int
    let stoppable: Int
    let actions: [BotRoomAction]
    var pending: Bool { !actions.isEmpty }
    init(_ value: BotJSON) {
        working = value["working"].flag == true
        blocked = value["blocked"].flag == true
        stopping = max(0, value["counts"]["stopping"].integer ?? 0)
        stoppable = max(0, value["counts"]["queued"].integer ?? 0) + max(0, value["counts"]["running"].integer ?? 0)
        actions = (value["pending_actions"].list ?? []).map(BotRoomAction.init)
    }
    var interval: Duration { working || blocked || stopping > 0 ? .seconds(2) : .seconds(10) }
}

struct BotRoomEvent: Identifiable, Equatable {
    let seq: Int
    let kind: String
    let actor: BotJSON
    let payload: BotJSON
    let timestamp: Double?
    var id: Int { seq }
    init?(_ value: BotJSON) {
        guard let seq = value["seq"].integer, seq > 0 else { return nil }
        self.seq = seq; kind = value["kind"].text ?? ""
        actor = value["actor"]; payload = value["payload"]; timestamp = value["created_at"].number
    }
    /// The events that open a dated stretch of a room. Only user and member
    /// messages carry a time; system rows neither show one nor date a gap.
    static func gapStarts(in events: some Sequence<BotRoomEvent>) -> Set<Int> {
        TranscriptTimeline.gapStarts(events.map {
            (id: $0.seq, timestamp: ["message.user", "message.member"].contains($0.kind) ? $0.timestamp : nil)
        })
    }
    var visible: Bool {
        ["message.user", "message.member", "turn.failed", "turn.cancelled", "room.stop_requested", "room.renamed"].contains(kind)
    }
    func member(in room: BotGroupRoom) -> BotGroupRoom.Member? {
        let id = payload["member_id"].text ?? actor["id"].text
        return room.members.first { $0.id == id }
    }
    func sender(in room: BotGroupRoom) -> String {
        actor["display_name"].text ?? member(in: room)?.name ?? actor["profile"].text ?? String(localized: "Bot")
    }
    var systemText: String {
        switch kind {
        case "turn.failed": return payload["error"].text.map { String(localized: "Failed: \($0)") } ?? String(localized: "Turn failed")
        case "turn.cancelled": return String(localized: "Turn cancelled")
        case "room.stop_requested": return String(localized: "Stop requested")
        case "room.renamed": return String(localized: "Room renamed to \(payload["name"].text ?? "")")
        default: return ""
        }
    }
}

/// Pure replay seam. Invisible events still advance the cursor and occupy their
/// sequence number. An unchanged page leaves the visible transcript untouched.
struct BotRoomLog {
    private(set) var cursor = 0
    private(set) var earlierBoundary = 0
    private(set) var events: [BotRoomEvent] = []
    private var seen = Set<Int>()
    static func windowStart(before sequence: Int) -> Int { max(0, sequence - 200) }
    /// Preserve system rows and the replay cursor without keeping an unbounded
    /// seen-set or the entire paged history alive after leaving the room.
    func recentWindow() -> Self {
        var result = self
        result.events = Array(events.suffix(500))
        if events.count > 500, let first = result.events.first {
            result.earlierBoundary = max(earlierBoundary, first.seq - 1)
        }
        result.seen = Set(result.events.map(\.seq))
        return result
    }
    mutating func begin(latest: Int) {
        self = Self(); cursor = Self.windowStart(before: latest); earlierBoundary = cursor
    }
    mutating func loadedEarlier(from start: Int) { earlierBoundary = start }
    /// An acknowledgment can arrive ahead of unread log events. Insert its bubble
    /// without skipping those events on the next log read.
    mutating func acknowledge(_ event: BotJSON) {
        let previous = cursor
        apply(.object(["events": .array([event])]))
        cursor = previous
    }
    mutating func apply(_ page: BotJSON) {
        let fresh = (page["events"].list ?? []).compactMap(BotRoomEvent.init).filter { seen.insert($0.seq).inserted }
        cursor = max(cursor, page["cursor"].integer ?? 0, fresh.map(\.seq).max() ?? 0)
        let visible = fresh.filter(\.visible)
        if !visible.isEmpty { events = (events + visible).sorted { $0.seq < $1.seq } }
    }
}

/// Typed room reads, participation and lifecycle commands; never peer administration.
enum BotRoomRPC {
    static let methods = ["groups.capabilities", "groups.list", "groups.state", "groups.log",
                          "groups.send", "groups.stop", "groups.approve", "groups.retry",
                          "groups.create", "groups.rename", "groups.disband"]
    static func validID(_ id: String) -> Bool {
        id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z", options: .regularExpression) != nil
    }
    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 64 * 1024
    }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= 200
    }
    static func validate(_ method: String, _ params: [String: BotJSON]) throws {
        guard method.hasPrefix("groups.") else { return }
        let allowed: Set<String>
        switch method {
        case "groups.capabilities": allowed = []
        case "groups.list": allowed = ["limit", "offset", "include_disbanded"]
        case "groups.state": allowed = ["room_id", "include_disbanded"]
        case "groups.log": allowed = ["room_id", "since_seq", "limit"]
        case "groups.send": allowed = ["room_id", "event_id", "payload"]
        case "groups.stop": allowed = ["room_id", "cancel_id"]
        case "groups.approve": allowed = ["room_id", "member_id", "task_id", "execution_generation", "choice", "request_id"]
        case "groups.retry": allowed = ["room_id", "task_id"]
        case "groups.create": allowed = ["room_id", "name", "members"]
        case "groups.rename": allowed = ["room_id", "event_id", "name"]
        case "groups.disband": allowed = ["room_id"]
        default: throw BotFailure.unsupported
        }
        guard Set(params.keys).isSubset(of: allowed) else { throw BotFailure.unsupported }
        if method != "groups.capabilities" && method != "groups.list" {
            guard let id = params["room_id"]?.text, validID(id) else { throw BotFailure.unsupported }
        }
        switch method {
        case "groups.create":
            guard let name = params["name"]?.text, validName(name),
                  let members = params["members"]?.list, (2...6).contains(members.count) else { throw BotFailure.unsupported }
            var ids = Set<String>(), profiles = Set<String>(), handles: Set<String> = ["all", "everyone"]
            for member in members {
                guard let fields = member.fields,
                      Set(fields.keys).isSubset(of: ["member_id", "profile", "handle", "display_name"]),
                      let id = member["member_id"].text, validID(id), ids.insert(id.lowercased()).inserted,
                      let profile = member["profile"].text, validID(profile), profiles.insert(profile.lowercased()).inserted,
                      let handle = member["handle"].text, validID(handle), handles.insert(handle.lowercased()).inserted,
                      id == profile, handle == profile || (profile == "default" && handle == "hermes")
                else { throw BotFailure.unsupported }
                if let display = fields["display_name"] {
                    guard let text = display.text, text.unicodeScalars.count <= 200 else { throw BotFailure.unsupported }
                }
            }
        case "groups.rename":
            guard let name = params["name"]?.text, validName(name),
                  let id = params["event_id"]?.text, validID(id) else { throw BotFailure.unsupported }
        case "groups.send":
            guard let eventID = params["event_id"]?.text, validID(eventID),
                  let payload = params["payload"]?.fields, Set(payload.keys) == ["text", "thread_id"],
                  let text = payload["text"]?.text, validText(text),
                  let thread = payload["thread_id"]?.text, validID(thread) else { throw BotFailure.unsupported }
        case "groups.stop":
            if let cancel = params["cancel_id"] {
                guard let id = cancel.text, validID(id) else { throw BotFailure.unsupported }
            }
        case "groups.approve":
            guard let choice = params["choice"]?.text, ["once", "deny"].contains(choice),
                  let generation = params["execution_generation"]?.integer, generation > 0 else { throw BotFailure.unsupported }
            for key in ["member_id", "task_id", "request_id"] {
                guard let id = params[key]?.text, validID(id) else { throw BotFailure.unsupported }
            }
        case "groups.retry":
            guard let id = params["task_id"]?.text, validID(id) else { throw BotFailure.unsupported }
        default: break
        }
        for key in ["limit", "offset", "since_seq"] where params[key] != nil {
            guard let n = params[key]?.integer, n >= (key == "limit" ? 1 : 0),
                  key != "limit" || n <= 500 else { throw BotFailure.unsupported }
        }
        if let value = params["include_disbanded"], value.flag == nil { throw BotFailure.unsupported }
    }
}

struct BotRoomFailure: Error, LocalizedError {
    let code: Int
    let reason: String?
    var expired: Bool { code == 4114 || reason == "room_history_expired" }
    var errorDescription: String? {
        if expired { return String(localized: "This room’s history is no longer available.") }
        if code == 4123 { return String(localized: "Restart the Hermes gateway on your Mac, then reconnect.") }
        return BotFailure.rejected(code).localizedDescription
    }
}
