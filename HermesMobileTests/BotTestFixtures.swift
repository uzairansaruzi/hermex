import XCTest
import Observation
import SwiftUI
@testable import HermesMobile

final class BotSocketHost: @unchecked Sendable {
    struct Reply {
        var result: BotJSON = .object([:])
        var error: Int?
        var message = "refused"
        var data: BotJSON = .null
        var before: [BotJSON] = []
    }

    private let lock = NSLock()
    private var standing: [String: Reply] = [
        "session.list": Reply(result: .object(["sessions": .array([.object(["id": .string("root"), "resolved_id": .string("tip")])])])),
        "subagent.list": Reply(result: .object(["subagents": .array([]), "delegations": .array([])]))
    ]
    private var queued: [String: [Reply]] = [:]
    private var withheld: Set<String> = []
    private var stalledOpen: XCTestExpectation?
    private var log: [BotJSON] = []
    private var waiters: [(method: String, expectation: XCTestExpectation)] = []

    var requests: [BotJSON] { lock.withLock { log } }

    func always(_ method: String, _ reply: Reply) { lock.withLock { standing[method] = reply } }
    func next(_ method: String, _ reply: Reply) { lock.withLock { queued[method, default: []].append(reply) } }
    func withhold(_ method: String) { lock.withLock { _ = withheld.insert(method) } }
    func allow(_ method: String) { lock.withLock { _ = withheld.remove(method) } }
    func stallReady(_ opened: XCTestExpectation) { lock.withLock { stalledOpen = opened } }
    func expect(_ expectation: XCTestExpectation, onNext method: String) {
        lock.withLock { waiters.append((method, expectation)) }
    }

    func transcriptReads(since index: Int) -> [Bool] {
        requests.dropFirst(index).filter { $0["method"].text == "session.resume" }
            .map { $0["params"]["omit_messages"].flag != true }
    }

    @MainActor func connection(_ record: BotConnection, rpcDeadline: Duration = .seconds(30), canonical: Bool = false,
                               rest: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) -> HermesConnection {
        let ready = canonical ? #"{"replay_epoch":"socket-epoch","session_authority":true}"# : #"{"replay_epoch":"epoch"}"#
        return HermesConnection(connection: record, configuration: HermesHostFixture.configuration(rest),
                         gateway: .init(rpcDeadline: rpcDeadline, socketFactory: { [self] _ in
                             let stalled = lock.withLock { defer { stalledOpen = nil }; return stalledOpen }
                             stalled?.fulfill()
                             let socket = BotScriptedSocket(ready: stalled == nil ? ready : nil)
                             socket.reply = { [weak socket, self] request in answer(request, on: socket) }
                             socket.withholdReply = { [self] request in
                                 guard lock.withLock({ withheld.contains(request["method"].text ?? "") }) else { return false }
                                 _ = answer(request, on: nil)
                                 return true
                             }
                             return socket
                         }))
    }

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
            return .object(["id": request["id"], "error": .object(["code": .number(Double(code)), "message": .string(reply?.message ?? "refused"),
                                                                    "data": reply?.data ?? .null])])
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
    @MainActor func settle(_ window: UIWindow, passes: Int = 3) async {
        for _ in 0..<passes {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

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
        _ = XCTWaiter().wait(for: [shown], timeout: 60)
        field.resignFirstResponder()
        window.isHidden = true
    }

    @MainActor private static var softwareKeyboardIsWarm = false

    @MainActor func host(_ content: some View, phase driver: ScenePhaseDriver) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: ScenePhased(driver: driver, content: content))
        window.makeKeyAndVisible()
        return window
    }
}

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
    var turnStartedAt: Double?
    var queued = BotJSON.null
    var attention = false
    var pendingApproval: BotJSON?
    var openClarify = BotJSON.null
    var openRequests = BotJSON.null
    var pendingConnection = BotJSON.null
    var connectionRespond: (([String: BotJSON]) throws -> BotJSON)?
    var answerRequest: ((String, [String: BotJSON]) throws -> BotJSON)?
    var approvalResolved = 1
    var answerStatus = "ok"
    var respondFailure: BotFailure?
    var todoState = BotJSON.null
    var history: [BotJSON] = [.object(["role": .string("assistant"), "text": .string("saved")])]
    var replay = BotFixtureWire.replay()
    var settingsCall: ((String, [String: BotJSON]) -> BotJSON)?
    var lookupFailure: BotFailure?
    var submitFailure: BotFailure?
    var catalog: BotJSON?
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
    var imageUpload: ((Data, String, BotArtifactContext) async throws -> BotUploadedImage)?
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> BotUploadedImage {
        guard let imageUpload else { throw BotFailure.unsupported }
        return try await imageUpload(data, filename, context)
    }
    var downloadArtifact: ((String, BotArtifactContext) async throws -> Data)?
    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data {
        guard let downloadArtifact else { throw BotArtifactFailure.unavailable }
        return try await downloadArtifact(path, context)
    }
    var platformNotes: [String] = []
    func keepPlatformNote(profile: String) async { platformNotes.append("\(profile) after \(calls.count) calls") }
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
    private var openRequestsWithClarify: BotJSON {
        guard var params = openClarify.fields else { return openRequests }
        let id = params.removeValue(forKey: "request_id") ?? .string("clr")
        params["session_id"] = .string(runtimeID)
        let frame = BotJSON.object(["id": id, "method": .string("clarify"), "params": .object(params)])
        return .array((openRequests.list ?? []) + [frame])
    }

    static func approval(id: String = "req-1", command: String = "rm -rf build",
                         choices: [String] = ["once", "session", "always", "deny"]) -> BotJSON {
        .object([
            "request_id": .string(id), "command": .string(command),
            "description": .string("recursive delete"), "pattern_key": .string("rm"),
            "choices": .array(choices.map(BotJSON.string))
        ])
    }

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
