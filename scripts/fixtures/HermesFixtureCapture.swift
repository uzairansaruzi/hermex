import Foundation

/// Records what a live hermes-agent host sends for the Bot surfaces Hermex reads, and
/// writes it as sanitized JSON fixtures for `HermesAgentFixtureTests`. Run it through
/// `scripts/capture-hermes-fixtures`, which compiles this file and supplies the
/// `hermex-bot` Keychain credentials in the environment.
///
/// The capture signs in like `BotClient.connect`, reads `/api/status` and
/// `profiles.list`, runs one canned turn in a disposable hidden session on the
/// `inbox-triage` bot, resumes it, then closes and deletes it. Nothing reaches disk
/// until the allow-list sanitizer and the leak check have both passed.
@main
struct HermesFixtureCapture {
    static let profile = "inbox-triage"
    static let title = "hermex-fixture-capture"
    static let prompt = "Reply with exactly: ok. Do not use tools."

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            guard let root = arguments.first else { throw Failure("usage: HermesFixtureCapture <repo-root> [--keep-raw <file> | --from-raw <file>]") }
            let options = try Options(Array(arguments.dropFirst()))
            let repo = URL(fileURLWithPath: root)
            let pin = try Pin(repo.appendingPathComponent("HERMES_AGENT_TESTED_SHA"))
            var secrets = try Secrets.fromEnvironment()
            let raw: JSON
            if let source = options.fromRaw {
                raw = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: source))
            } else {
                (raw, secrets.ticket) = try await Capture(secrets: secrets, pin: pin).run()
                if let keep = options.keepRaw {
                    try encode(raw).write(to: keep, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keep.path)
                    print("Kept the unsanitized capture at \(keep.path); move it to the Trash when done.")
                }
            }
            let files = try Sanitizer.fixtures(raw: raw, pin: pin)
            try LeakCheck.verify(files, raw: raw, secrets: secrets)
            let directory = repo.appendingPathComponent("HermesMobileTests/Fixtures/HermesAgent")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            print("Wrote \(files.count) fixtures to HermesMobileTests/Fixtures/HermesAgent.")
        } catch {
            FileHandle.standardError.write(Data("capture-hermes-fixtures: \(error)\n".utf8))
            exit(1)
        }
    }

    static func encode(_ value: JSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder spreads an empty container over three lines. A raw newline
        // never occurs inside an encoded string, so this touches only structure.
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
            .replacingOccurrences(of: "\\[\n\n *\\]", with: "[]", options: .regularExpression)
            .replacingOccurrences(of: "\\{\n\n *\\}", with: "{}", options: .regularExpression)
        return Data((text + "\n").utf8)
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var keepRaw: URL?
    var fromRaw: URL?
    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw Failure("\(flag) needs a file") }
            switch flag {
            case "--keep-raw": keepRaw = URL(fileURLWithPath: value)
            case "--from-raw": fromRaw = URL(fileURLWithPath: value)
            default: throw Failure("unknown option \(flag)")
            }
        }
        if keepRaw != nil, fromRaw != nil { throw Failure("--keep-raw and --from-raw are exclusive") }
    }
}

/// `HERMES_AGENT_TESTED_SHA`: line 1 the commit, line 2 the release. The capture
/// refuses a host on another release, so the manifest always names the pin.
struct Pin {
    let sha: String
    let release: String
    init(_ file: URL) throws {
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { throw Failure("HERMES_AGENT_TESTED_SHA needs a commit and a release line") }
        sha = lines[0]; release = lines[1]
    }
}

/// Values that must never appear in a fixture. Read from the environment the
/// wrapper sets; never printed.
struct Secrets {
    let address: URL
    let host: String
    let username: String
    let password: String
    var ticket: String?

    static func fromEnvironment() throws -> Secrets {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["HERMEX_CAPTURE_ADDRESS"], let address = URL(string: text), let host = address.host,
              let username = env["HERMEX_CAPTURE_USERNAME"], !username.isEmpty,
              let password = env["HERMEX_CAPTURE_PASSWORD"], !password.isEmpty
        else { throw Failure("missing hermex-bot credentials; see the header of scripts/capture-hermes-fixtures") }
        return Secrets(address: address, host: host, username: username, password: password)
    }
}

// MARK: - JSON

/// The same tolerant shape as the app's `BotJSON`, kept separate so this helper
/// compiles on its own.
indirect enum JSON: Codable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v):
            if let whole = Int64(exactly: v) { try c.encode(whole) } else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var list: [JSON]? { if case .array(let v) = self { return v }; return nil }
    var fields: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    var flag: Bool? { if case .bool(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self { return Int(exactly: v) }; return nil }
}

// MARK: - Live capture

/// One sequential conversation with the host. Every inbound frame is kept in
/// order; RPC replies are matched by id as they arrive.
final class Capture {
    private let secrets: Secrets
    private let pin: Pin
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var frames: [JSON] = []
    private var nextID = 0

    init(secrets: Secrets, pin: Pin) { self.secrets = secrets; self.pin = pin }

    /// Returns the raw capture and the socket ticket, which the leak check needs
    /// but the raw capture never stores.
    func run() async throws -> (JSON, String) {
        let status = try await http("api/status")
        guard status["version"].text == pin.release else {
            throw Failure("the host reports \(status["version"].text ?? "no version"), the pin is \(pin.release). Update HERMES_AGENT_TESTED_SHA to the host's commit and release first.")
        }
        guard status["auth_required"].flag == true, status["auth_providers"].list?.contains(.string("basic")) == true else {
            throw Failure("the host has no basic auth gate")
        }
        _ = try await http("auth/password-login", body: .object([
            "provider": .string("basic"), "username": .string(secrets.username), "password": .string(secrets.password)
        ]))
        guard try await http("api/auth/me")["provider"].text == "basic" else { throw Failure("unexpected identity provider") }
        guard let ticket = try await http("api/auth/ws-ticket", body: .object([:]))["ticket"].text, !ticket.isEmpty else {
            throw Failure("no socket ticket")
        }
        var parts = URLComponents(url: secrets.address.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = secrets.address.scheme == "https" ? "wss" : "ws"
        let task = session.webSocketTask(with: parts.url!, protocols: ["hermes-gateway-v1", "hermes-gateway-ticket." + ticket])
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        socket = task
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let ready = try await receive(timeout: 30)
        guard ready["params"]["type"].text == "gateway.ready" else { throw Failure("the socket did not open with gateway.ready") }
        // The same first frame BotClient sends, so the host treats this socket as Hermex.
        _ = try await call("client.capabilities", ["server_requests": .bool(true)])
        let profiles = try await call("profiles.list", ["include_sessions": .bool(true)])

        var runtimes: [String] = []
        var stored: String?
        do {
            let create = try await call("session.create", [
                "profile": .string(HermesFixtureCapture.profile), "title": .string(HermesFixtureCapture.title),
                "hidden": .bool(true), "follow_profile_config": .bool(true), "close_on_disconnect": .bool(true)
            ])
            guard let runtime = create["session_id"].text, let storedID = create["stored_session_id"].text else {
                throw Failure("session.create returned no ids")
            }
            runtimes.append(runtime); stored = storedID
            print("Disposable session: stored id \(storedID).")
            let firstFrame = frames.count
            _ = try await call("prompt.submit", ["session_id": .string(runtime), "text": .string(HermesFixtureCapture.prompt), "queued": .bool(true)])
            try await waitForSettledTurn(runtime: runtime, from: firstFrame)
            // `hidden` should keep the session out of Desktop's ordinary list. A title
            // lookup ignores `hidden`, so compare the plain listings instead.
            let visible = try await listed(storedID, includeHidden: false)
            let listedWithHidden = try await listed(storedID, includeHidden: true)
            print("Hidden check: \(visible ? "LISTED" : "absent") without include_hidden, \(listedWithHidden ? "listed" : "ABSENT") with it.")
            let resume = try await call("session.resume", [
                "profile": .string(HermesFixtureCapture.profile), "session_id": .string(storedID), "close_on_disconnect": .bool(false)
            ])
            if let id = resume["session_id"].text, !runtimes.contains(id) { runtimes.append(id) }
            guard resume["running"].flag == false else { throw Failure("session.resume reports the turn still running") }
            try await cleanUp(runtimes: runtimes, stored: storedID)
            return (.object([
                "status": status, "profiles": profiles, "resume": resume, "runtime_id": .string(runtime), "frames": .array(frames),
                "captured_at": .string(ISO8601DateFormatter().string(from: Date()))
            ]), ticket)
        } catch {
            do { try await cleanUp(runtimes: runtimes, stored: stored) } catch let cleanup {
                throw Failure("\(error); cleanup also failed (\(cleanup)). Remove by hand: runtime ids \(runtimes), stored id \(stored ?? "none")")
            }
            throw error
        }
    }

    /// Closes every runtime the capture touched, then deletes the stored row and
    /// confirms it is gone. The row exists only after the first prompt, so a
    /// delete that finds nothing is a clean exit, not a failure.
    private func cleanUp(runtimes: [String], stored: String?) async throws {
        for runtime in runtimes { _ = try await call("session.close", ["session_id": .string(runtime)]) }
        guard let stored else { return }
        for attempt in 1...5 {
            do {
                _ = try await call("session.delete", ["profile": .string(HermesFixtureCapture.profile), "session_id": .string(stored)])
                break
            } catch let failure as RPCFailure where failure.code == 4007 {
                break
            } catch let failure as RPCFailure where failure.code == 4023 && attempt < 5 {
                // Close tears the runtime down asynchronously; delete is refused until it is gone.
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard try await !listed(stored, includeHidden: true) else { throw Failure("session.list still returns the disposable session") }
        print("Disposable session \(stored) closed and deleted.")
    }

    /// Whether the Profile's recent-session listing (not a title lookup) returns `stored`.
    private func listed(_ stored: String, includeHidden: Bool) async throws -> Bool {
        let reply = try await call("session.list", ["profile": .string(HermesFixtureCapture.profile), "include_hidden": .bool(includeHidden)])
        guard let rows = reply["sessions"].list else { throw Failure("session.list returned no sessions array") }
        return rows.contains { $0["id"].text == stored }
    }

    /// Reads until the runtime's first `session.info` with `running: false` after
    /// `message.complete`; the host emits `message.complete` before post-turn work.
    private func waitForSettledTurn(runtime: String, from start: Int) async throws {
        let deadline = Date().addingTimeInterval(180)
        var index = start
        var completed = false
        while true {
            while index < frames.count {
                let params = frames[index]["params"]
                index += 1
                guard frames[index - 1]["method"].text == "event", params["session_id"].text == runtime else { continue }
                if params["type"].text == "message.complete" { completed = true }
                if completed, params["type"].text == "session.info", params["payload"]["running"].flag == false { return }
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure("the turn did not settle within 180 s") }
            frames.append(try await receive(timeout: remaining))
        }
    }

    private func http(_ path: String, body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: secrets.address.appendingPathComponent(path))
        request.timeoutInterval = 20
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("\(path) answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    private func call(_ method: String, _ params: [String: JSON]) async throws -> JSON {
        guard let socket else { throw Failure("no socket") }
        nextID += 1
        let id = nextID
        let frame = JSON.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
        try await socket.send(.string(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)))
        while true {
            let reply = try await receive(timeout: 30)
            guard reply["id"].integer == id, reply["method"] == .null else { frames.append(reply); continue }
            if let code = reply["error"]["code"].integer { throw RPCFailure(method: method, code: code) }
            return reply["result"]
        }
    }

    private func receive(timeout: TimeInterval) async throws -> JSON {
        guard let socket else { throw Failure("no socket") }
        return try await withThrowingTaskGroup(of: JSON.self) { group in
            group.addTask {
                let data: Data
                switch try await socket.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw Failure("unknown socket frame")
                }
                return try JSONDecoder().decode(JSON.self, from: data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // A pending receive ignores task cancellation; closing the socket ends it.
                socket.cancel(with: .goingAway, reason: nil)
                throw Failure("the host was silent for \(Int(timeout)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

struct RPCFailure: Error, CustomStringConvertible {
    let method: String
    let code: Int
    var description: String { "\(method) failed with JSON-RPC error \(code)" }
}

// MARK: - Sanitizer

/// Turns a raw capture into fixture files. Strings are replaced unless their key
/// is on the allow-list, so a field upstream adds later is redacted by default.
enum Sanitizer {
    static let placeholder = "fixture-redacted"
    /// String values the tests read: ids, event and status vocabulary, the release.
    static let keptStrings: Set<String> = [
        "id", "session_id", "stored_session_id", "session_key", "resolved_id",
        "jsonrpc", "method", "type", "status", "role", "version"
    ]
    static let identities: Set<String> = ["install_id", "installation_id", "authority_gateway_id"]
    static let paths: Set<String> = ["path", "cwd", "hermes_home", "config_path", "env_path", "git_repo_root"]
    static let emptied: Set<String> = ["mcp_servers", "tools", "skills"]

    static func fixtures(raw: JSON, pin: Pin) throws -> [String: Data] {
        let status = raw["status"]
        guard status["version"].text == pin.release else { throw Failure("the capture is from \(status["version"].text ?? "an unknown release"), the pin is \(pin.release)") }
        guard let runtime = raw["runtime_id"].text, let frames = raw["frames"].list else { throw Failure("the capture has no turn") }

        var statusFields = status.fields ?? [:]
        for key in ["profiles", "gateway_shared_with"] where statusFields[key]?.list != nil {
            statusFields[key] = .array([.string(HermesFixtureCapture.profile)])
        }
        if let parked = statusFields["parked_profiles"]?.list {
            statusFields["parked_profiles"] = .array(parked.filter { $0.text == HermesFixtureCapture.profile })
        }
        // Keyed by the host's configured messaging platforms, which are not ours to publish.
        if statusFields["gateway_platforms"]?.fields != nil { statusFields["gateway_platforms"] = .object([:]) }

        var roster = raw["profiles"].fields ?? [:]
        let rows = roster["profiles"]?.list?.filter { $0["name"].text == HermesFixtureCapture.profile } ?? []
        guard rows.count == 1, rows[0]["canonical_session"].fields != nil else {
            throw Failure("profiles.list has no \(HermesFixtureCapture.profile) row with a canonical_session")
        }
        roster["profiles"] = .array(rows)

        let turn = try settledTurn(frames, runtime: runtime)
        let manifest = JSON.object([
            "hermes_agent_sha": .string(pin.sha), "version": .string(pin.release),
            "captured_at": .string(raw["captured_at"].text ?? ISO8601DateFormatter().string(from: Date()))
        ])
        return [
            "manifest.json": try HermesFixtureCapture.encode(manifest),
            "status.json": try HermesFixtureCapture.encode(clean(.object(statusFields), transcript: false)),
            "profiles-list.json": try HermesFixtureCapture.encode(clean(.object(roster), transcript: false)),
            "session-resume.json": try HermesFixtureCapture.encode(clean(raw["resume"], transcript: true)),
            "turn-frames.json": try HermesFixtureCapture.encode(clean(.array(turn), transcript: true))
        ]
    }

    /// The runtime's event frames up to and including the settled `session.info`.
    /// Anything that means the canned turn used a tool or asked the user aborts.
    static func settledTurn(_ frames: [JSON], runtime: String) throws -> [JSON] {
        var kept: [JSON] = []
        var completed = false
        for frame in frames {
            let params = frame["params"]
            guard params["session_id"].text == runtime else { continue }
            guard frame["method"].text == "event", frame["id"] == .null else {
                throw Failure("the host sent a \(frame["method"].text ?? "") request during the canned turn")
            }
            let type = params["type"].text ?? ""
            if ["tool.", "approval.", "clarify."].contains(where: type.hasPrefix) || type.hasSuffix(".request") {
                throw Failure("the canned turn emitted \(type); the fixture must not contain tool or request traffic")
            }
            kept.append(frame)
            if type == "message.complete" { completed = true }
            if completed, type == "session.info", params["payload"]["running"].flag == false { return kept }
        }
        throw Failure("the capture never settled")
    }

    /// Applies the allow-list. `transcript` also keeps `text`, which only the
    /// disposable session's canned prompt and reply carry.
    static func clean(_ value: JSON, key: String? = nil, transcript: Bool) -> JSON {
        if let key, emptied.contains(key) {
            if value.list != nil { return .array([]) }
            if value.fields != nil { return .object([:]) }
        }
        switch value {
        case .object(let fields):
            return .object(fields.reduce(into: [:]) { $0[$1.key] = clean($1.value, key: $1.key, transcript: transcript) })
        case .array(let items):
            return .array(items.map { clean($0, key: key, transcript: transcript) })
        case .string(let text):
            guard let key else { return .string(placeholder) }
            if identities.contains(key) { return .string("fixture-install") }
            if paths.contains(key) { return .string("/fixture/\(key)") }
            if text == HermesFixtureCapture.profile || keptStrings.contains(key) || (transcript && key == "text")
                || (key == "auth_providers") { return .string(text) }
            return .string(placeholder)
        default:
            return value
        }
    }
}

// MARK: - Leak check

/// The last gate before disk: the serialized fixtures must not contain the host,
/// the account, the ticket, a home path, the raw install id, or another Profile.
enum LeakCheck {
    static func verify(_ files: [String: Data], raw: JSON, secrets: Secrets) throws {
        let output = files.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        var forbidden = [secrets.host, secrets.username, secrets.password, "/Users/"]
        if let ticket = secrets.ticket { forbidden.append(ticket) }
        for key in Sanitizer.identities { forbidden += values(of: key, in: raw) }
        for value in forbidden where !value.isEmpty && output.range(of: value, options: .caseInsensitive) != nil {
            throw Failure("a sanitized fixture still contains a secret value; nothing was written")
        }
        let others = (raw["status"]["profiles"].list ?? []).compactMap(\.text).filter { $0 != HermesFixtureCapture.profile }
        for name in others {
            let word = "(?<![A-Za-z0-9_.-])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_-])"
            if output.range(of: word, options: .regularExpression) != nil {
                throw Failure("a sanitized fixture names a Profile other than \(HermesFixtureCapture.profile); nothing was written")
            }
        }
    }

    private static func values(of key: String, in value: JSON) -> [String] {
        switch value {
        case .object(let fields):
            return fields.flatMap { ($0.key == key ? [$0.value.text].compactMap { $0 } : []) + values(of: key, in: $0.value) }
        case .array(let items): return items.flatMap { values(of: key, in: $0) }
        default: return []
        }
    }
}
