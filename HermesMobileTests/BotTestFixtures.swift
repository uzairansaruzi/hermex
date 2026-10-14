import XCTest
import Observation
import SwiftUI
@testable import HermesMobile

/// A Hermes host scripted at the socket, so a Hermes chat runs over a real
/// `BotClient` and the shared `HermesGateway`. A reply can follow live frames, as the
/// host's event thread writes them ahead of it, which `BotFixtureWire` cannot show.
/// Sockets answer off the main actor, so the script is locked.
final class BotSocketHost: @unchecked Sendable {
    struct Reply {
        var result: BotJSON = .object([:])
        /// A JSON-RPC error code answered instead of `result`.
        var error: Int?
        /// The error's message.
        var message = "refused"
        /// Event frames written ahead of the reply.
        var before: [BotJSON] = []
    }

    private let lock = NSLock()
    private var standing: [String: Reply] = [
        "session.list": Reply(result: .object(["sessions": .array([.object(["id": .string("root"), "resolved_id": .string("tip")])])])),
        "subagent.list": Reply(result: .object(["subagents": .array([]), "delegations": .array([])]))
    ]
    private var queued: [String: [Reply]] = [:]
    private var withheld: Set<String> = []
    private var log: [BotJSON] = []
    private var waiters: [(method: String, expectation: XCTestExpectation)] = []

    /// Every request the conversation sent, across its sockets, handshakes excluded.
    var requests: [BotJSON] { lock.withLock { log } }

    /// Answers every later `method` call with `reply`.
    func always(_ method: String, _ reply: Reply) { lock.withLock { standing[method] = reply } }
    /// Answers the next `method` call with `reply`, ahead of any standing one.
    func next(_ method: String, _ reply: Reply) { lock.withLock { queued[method, default: []].append(reply) } }
    /// Leaves every later `method` call unanswered, as a reply the socket lost; it is still
    /// logged.
    func withhold(_ method: String) { lock.withLock { _ = withheld.insert(method) } }
    /// Fulfills `expectation` when the next `method` call arrives.
    func expect(_ expectation: XCTestExpectation, onNext method: String) {
        lock.withLock { waiters.append((method, expectation)) }
    }

    /// For each `session.resume` from request `index` on, whether it asked for the transcript.
    func transcriptReads(since index: Int) -> [Bool] {
        requests.dropFirst(index).filter { $0["method"].text == "session.resume" }
            .map { $0["params"]["omit_messages"].flag != true }
    }

    /// A connection to this host: an ordinary sign-in, then a scripted socket per open.
    /// `rpcDeadline` shortens how long an unanswered call waits.
    @MainActor func connection(_ record: BotConnection, rpcDeadline: Duration = .seconds(30)) -> HermesConnection {
        HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                         gateway: .init(rpcDeadline: rpcDeadline, socketFactory: { [self] _ in
                             let socket = BotScriptedSocket()
                             socket.reply = { [weak socket, self] request in answer(request, on: socket) }
                             socket.withholdReply = { [self] request in
                                 guard lock.withLock({ withheld.contains(request["method"].text ?? "") }) else { return false }
                                 _ = answer(request, on: nil) // logged and awaited like any call; its answer is dropped
                                 return true
                             }
                             return socket
                         }))
    }

    /// Without a script, `session.resume` answers with the running turn, honouring
    /// `omit_messages` as the host does, and any other method is unknown.
    private func answer(_ request: BotJSON, on socket: BotScriptedSocket?) -> BotJSON {
        let method = request["method"].text ?? ""
        let (reply, fulfilled): (Reply?, [XCTestExpectation]) = lock.withLock {
            log.append(request)
            let fulfilled = waiters.filter { $0.method == method }.map(\.expectation)
            waiters.removeAll { $0.method == method }
            if var replies = queued[method], !replies.isEmpty {
                let reply = replies.removeFirst()
                queued[method] = replies
                return (reply, fulfilled)
            }
            return (standing[method], fulfilled)
        }
        fulfilled.forEach { $0.fulfill() }
        for frame in reply?.before ?? [] {
            socket?.enqueue(Self.message(["method": .string("event"), "params": frame]))
        }
        if let code = reply?.error {
            return .object(["id": request["id"], "error": .object(["code": .number(Double(code)), "message": .string(reply?.message ?? "refused")])])
        }
        if let reply { return .object(["id": request["id"], "result": reply.result]) }
        guard method == "session.resume" else {
            return .object(["id": request["id"], "error": .object(["code": .number(-32601), "message": .string("unknown method")])])
        }
        let omitted = request["params"]["omit_messages"].flag == true
        return .object(["id": request["id"], "result": .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(true),
            "messages": .array(omitted ? [] : [.object(["role": .string("assistant"), "text": .string("saved")])]),
            "messages_omitted": .bool(omitted), "info": .object(["profile_name": .string("inbox-triage")])
        ])])
    }

    private static func message(_ fields: [String: BotJSON]) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: (try? JSONEncoder().encode(BotJSON.object(fields))) ?? Data(), as: UTF8.self))
    }
}

extension XCTestCase {
    /// Lets a hosted SwiftUI window apply pending state before a test reads it.
    /// Each pass yields one main-queue turn, so queued main-actor work (a view's
    /// `.task`, an observation callback, a deferred focus change) runs, then
    /// lays the window out, which is where the hosting view applies that state.
    /// Display cadence plays no part, so a runner whose display link stalls
    /// cannot time a test out. Content produced off the main queue needs its own
    /// signal: await the model first, or read until the content shows.
    @MainActor func settle(_ window: UIWindow, passes: Int = 3) async {
        for _ in 0..<passes {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

    /// A freshly cloned CI simulator boots without the keyboard daemon. The first
    /// focus change after a text view takes focus blocks the main thread inside
    /// UIKit until `kbd` answers, which took 5–30 s on hosted runners, so no
    /// wait's ceiling is safe while it starts. Classes that focus text views call
    /// this from `class setUp()`, where no clock runs; later calls return at once.
    @MainActor static func warmUpSoftwareKeyboard() {
        guard !softwareKeyboardIsWarm,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        softwareKeyboardIsWarm = true
        let window = UIWindow(windowScene: scene)
        let field = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        window.addSubview(field)
        window.makeKeyAndVisible()
        let shown = XCTNSNotificationExpectation(name: UIResponder.keyboardWillShowNotification)
        field.becomeFirstResponder()
        // The keyboard is requested on focus; giving focus up is what waits for it.
        _ = XCTWaiter().wait(for: [shown], timeout: 5)
        field.resignFirstResponder()
        window.isHidden = true
    }

    @MainActor private static var softwareKeyboardIsWarm = false

    /// Hosts `content` in a window whose scene phase `driver` sets.
    @MainActor func host(_ content: some View, phase driver: ScenePhaseDriver) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: ScenePhased(driver: driver, content: content))
        window.makeKeyAndVisible()
        return window
    }
}

/// Stands in for the system's scene phase under a hosted screen, so a test can pull down
/// Control Center (`.inactive`) or go home (`.background`). Settle the window after each
/// change, so the screen sees every phase rather than only the last.
@MainActor @Observable final class ScenePhaseDriver {
    var phase: ScenePhase
    init(_ phase: ScenePhase) { self.phase = phase }
}

private struct ScenePhased<Content: View>: View {
    let driver: ScenePhaseDriver
    let content: Content
    var body: some View { content.environment(\.scenePhase, driver.phase) }
}

actor BotMemoryDrafts: ChatDraftPersisting {
    var values: [ChatDraftKey: ChatDraft] = [:]
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
}

@MainActor final class BotFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var calls: [(String, [String: BotJSON])] = []
    var root = "root"
    var tip = "tip"
    var runtimeID = "runtime"
    var running = false
    var inflight = BotJSON.null
    /// When the current turn began, as `turn_started_at`; nil for a host that sends none.
    var turnStartedAt: Double?
    var queued = BotJSON.null
    /// Shorthand for "a command approval is blocking this session"; set
    /// `pendingApproval` directly to control the payload.
    var attention = false
    var pendingApproval: BotJSON?
    /// A `clarify` server request in `open_requests`, in the `clarify()` shape:
    /// its `request_id` becomes the envelope id. Cleared once answered.
    var openClarify = BotJSON.null
    var openRequests = BotJSON.null
    /// The snapshot's `pending_connection`: an open `manage_connections` operation.
    var pendingConnection = BotJSON.null
    /// What `connection.respond` answers; by default `ok`, not settled.
    var connectionRespond: (([String: BotJSON]) throws -> BotJSON)?
    var answerRequest: ((String, [String: BotJSON]) throws -> BotJSON)?
    /// What `approval.respond` reports unblocking.
    var approvalResolved = 1
    /// What `request.answer` / `clarify.lock` report by default; "ok" or "expired".
    var answerStatus = "ok"
    var respondFailure: BotFailure?
    var todoState = BotJSON.null
    var history: [BotJSON] = [.object(["role": .string("assistant"), "text": .string("saved")])]
    var replay = BotFixtureWire.replay()
    var settingsCall: ((String, [String: BotJSON]) -> BotJSON)?
    var lookupFailure: BotFailure?
    var submitFailure: BotFailure?
    /// What `commands.catalog` answers, and what `command.dispatch` answers for a
    /// skill; nil means the host has no reply and the RPC fails.
    var catalog: BotJSON?
    /// Consumed before `catalog`, so a test can change the host's answer between reads.
    var catalogQueue: [BotJSON] = []
    var catalogFailure: BotFailure?
    var dispatch: BotJSON?
    var dispatchFailure: BotFailure?
    var promptReply: BotJSON?
    var stopFailure: BotFailure?
    var beforeDispatch: ((String) -> Void)?
    var beforeSubmit: (() async -> Void)?
    var beforeResume: (() async -> Void)?
    var transformResume: ((BotJSON) -> BotJSON)?
    var attachFile: (([String: BotJSON]) async throws -> BotJSON)?
    var imageUpload: ((Data, String, BotArtifactContext) async throws -> String)?
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        guard let imageUpload else { throw BotFailure.unsupported }
        return try await imageUpload(data, filename, context)
    }
    var downloadArtifact: ((String, BotArtifactContext) async throws -> Data)?
    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data {
        guard let downloadArtifact else { throw BotArtifactFailure.unavailable }
        return try await downloadArtifact(path, context)
    }
    var connectCount = 0
    var onConnect: (() -> Void)?
    func connect() async throws { connectCount += 1; onConnect?() }
    func close() {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let method = call.method, params = try call.params()
        beforeDispatch?(method)
        try validateDispatch?()
        calls.append((method, params))
        switch method {
        case "file.attach":
            guard let attachFile else { throw BotFailure.unsupported }
            return try await attachFile(params)
        case "session.list":
            if let lookupFailure {
                if lookupFailure == .missingChat { return .object(["sessions": .array([])]) }
                throw lookupFailure
            }
            return .object(["sessions": .array([.object(["id": .string(root), "resolved_id": .string(tip)])])])
        case "session.resume":
            await beforeResume?()
            let snapshot = BotJSON.object([
                "session_id": .string(runtimeID), "session_key": .string(tip), "running": .bool(running),
                "messages": .array(history), "inflight": inflight, "queued": queued,
                "turn_started_at": turnStartedAt.map(BotJSON.number) ?? .null,
                "pending_approval": pendingApproval ?? (attention ? BotFixtureWire.approval() : .null),
                "open_requests": openRequestsWithClarify,
                "pending_connection": pendingConnection,
                "todo_state": todoState,
                "info": .object(["profile_name": .string("inbox-triage")])
            ])
            return transformResume?(snapshot) ?? snapshot
        case "request.answer", "clarify.lock":
            if let respondFailure { throw respondFailure }
            if let answerRequest { return try answerRequest(method, params) }
            if answerStatus == "ok" { openRequests = .array([]); openClarify = .null }
            return .object(["status": .string(answerStatus), "remaining": .array([])])
        case "connection.respond":
            if let respondFailure { throw respondFailure }
            if let connectionRespond { return try connectionRespond(params) }
            return .object(["status": .string("ok"), "settled": .bool(false)])
        case "approval.respond":
            if let respondFailure { throw respondFailure }
            if approvalResolved > 0 { attention = false; pendingApproval = nil }
            return .object(["resolved": .number(Double(approvalResolved))])
        case "session.events.since": return replay
        case "subagent.list": return .object(["subagents": .array([]), "delegations": .array([])])
        case "commands.catalog":
            if let catalogFailure { throw catalogFailure }
            if !catalogQueue.isEmpty { return catalogQueue.removeFirst() }
            guard let catalog else { throw BotFailure.unsupported }
            return catalog
        case "command.dispatch":
            if let dispatchFailure { throw dispatchFailure }
            guard let dispatch else { throw BotFailure.unsupported }
            return dispatch
        case "prompt.submit", "session.steer", "session.redirect":
            await beforeSubmit?()
            if let submitFailure { throw submitFailure }
            running = true
            return promptReply ?? .object(["status": .string(method == "prompt.submit" ? "streaming" : "queued")])
        case "session.interrupt":
            if let stopFailure { throw stopFailure }
            return .object(["interrupted": .bool(true)])
        default:
            if let settingsCall { return settingsCall(method, params) }
            throw BotFailure.unsupported
        }
    }
    /// `openRequests` plus `openClarify` as its server-request envelope.
    private var openRequestsWithClarify: BotJSON {
        guard var params = openClarify.fields else { return openRequests }
        let id = params.removeValue(forKey: "request_id") ?? .string("clr")
        params["session_id"] = .string(runtimeID)
        let frame = BotJSON.object(["id": id, "method": .string("clarify"), "params": .object(params)])
        return .array((openRequests.list ?? []) + [frame])
    }

    /// The gateway's `_approval_request_payload` shape, as it reaches both the
    /// `approval` server request and the resume snapshot.
    static func approval(id: String = "req-1", command: String = "rm -rf build",
                         choices: [String] = ["once", "session", "always", "deny"]) -> BotJSON {
        .object([
            "request_id": .string(id), "command": .string(command),
            "description": .string("recursive delete"), "pattern_key": .string("rm"),
            "choices": .array(choices.map(BotJSON.string))
        ])
    }

    /// The single-question `clarify` shape, plus the id its envelope carries.
    static func clarify(id: String = "clr-1", question: String = "Which mailbox first?",
                        choices: [String] = ["Primary (Recommended)", "Follow-ups"],
                        multiSelect: Bool = false) -> BotJSON {
        .object([
            "request_id": .string(id), "question": .string(question),
            "choices": .array(choices.map(BotJSON.string)), "multi_select": .bool(multiSelect)
        ])
    }

    static func replay(latest: Int = 0, truncated: Bool = false, epoch: String = "epoch", events: [BotJSON] = []) -> BotJSON {
        .object(["latest_seq": .number(Double(latest)), "truncated": .bool(truncated), "epoch": .string(epoch), "events": .array(events)])
    }
}
