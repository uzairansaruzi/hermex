import Foundation

struct WebuiSource {
    let baseURL: URL
    let headers: [CustomHeader]
    let cookies: [HTTPCookie]

    init(baseURL: URL, headers: [CustomHeader], cookies: [HTTPCookie]? = nil) {
        self.baseURL = baseURL
        self.headers = headers
        self.cookies = cookies ?? HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
    }
}

enum WebuiSessionTransfer {
    static let sessionsPerImport = 500
    static let messagesPerImport = 50_000
    static let bytesPerImport = 25 * 1024 * 1024
    static let messagesPerSession = HermesSessionDuplication.messageLimit
    static let bytesPerSession = HermesSessionDuplication.byteLimit

    struct Item: Codable, Equatable, Sendable {
        let chat: MoveToHermesSourceChat
        let destination: String
    }

    enum Outcome: Codable, Equatable, Sendable {
        case imported(profile: String)
        case alreadyPresent(profile: String)
        case ambiguous(profiles: [String])
        case oversized
        case rejected(reason: String)
        case unreadable
        case unknown
        case uncertain(profile: String)
        case notSent
    }

    struct Dispatch: Codable, Equatable, Sendable {
        let destination: String
        let ids: [String]
    }

    @MainActor
    static func run(_ items: [Item], hermesProfiles: [String], source: WebuiSource, hermes: any BotTransport,
                    configuration: URLSessionConfiguration = .ephemeral,
                    willDispatch: @escaping @MainActor (Dispatch) async throws -> Void,
                    progress: @escaping @MainActor (_ settled: Int, _ total: Int) -> Void = { _, _ in }) async -> [String: Outcome] {
        var seen = Set<String>()
        let items = items.filter { seen.insert($0.chat.id).inserted }
        let attempt = Attempt(hermes: hermes, profiles: hermesProfiles, total: items.count,
                              willDispatch: willDispatch, progress: progress)
        let (webui, session) = APIClient.moveCopyClient(baseURL: source.baseURL, headers: source.headers,
                                                        cookies: source.cookies, configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in items {
            if groups[item.chat.profile] == nil { order.append(item.chat.profile) }
            groups[item.chat.profile, default: []].append(item)
        }
        for profile in order {
            let group = groups[profile] ?? []
            guard attempt.canSend else { attempt.settle(group.map(\.chat.id), .notSent); continue }
            do {
                let reply = try await webui.switchProfile(name: profile)
                guard (reply.error ?? "").isEmpty, (reply.active ?? profile) == profile else { throw BotFailure.unsupported }
            } catch {
                attempt.settle(group.map(\.chat.id), Task.isCancelled ? .notSent : .unreadable)
                continue
            }
            var pending: (destination: String, batch: [Prepared])?
            for start in stride(from: 0, to: group.count, by: MoveToHermesRequests.perServer) {
                let window = Array(group[start..<min(start + MoveToHermesRequests.perServer, group.count)])
                guard attempt.canSend else { attempt.settle(window.map(\.chat.id), .notSent); continue }
                let exports = await MoveToHermesRequests.map(window) { item in await export(item.chat.id, from: webui) }
                for (item, export) in zip(window, exports) {
                    switch export {
                    case .failed(let outcome):
                        attempt.settle([item.chat.id], outcome)
                    case .ready(let prepared):
                        if let held = pending, held.destination == item.destination,
                           fits(held.batch + [prepared], destination: held.destination) {
                            pending?.batch.append(prepared)
                        } else {
                            if let held = pending { await attempt.importBatch(held.batch, into: held.destination) }
                            pending = (item.destination, [prepared])
                        }
                    }
                }
            }
            if let held = pending { await attempt.importBatch(held.batch, into: held.destination) }
        }
        return attempt.outcomes
    }

    struct Prepared: Equatable, Sendable {
        let id: String
        let encoded: Data
        let messageCount: Int
    }

    enum Preparation: Equatable, Sendable {
        case ready(Prepared)
        case failed(Outcome)
    }

    nonisolated static func importRow(fromExport export: BotJSON, id: String) -> BotJSON? {
        guard export["session_id"].text == id, let messages = export["messages"].list else { return nil }
        var row: [String: BotJSON] = ["id": .string(id), "source": .string("webui"),
                                      "archived": .bool(export["archived"].flag ?? false)]
        if let started = export["created_at"].number { row["started_at"] = .number(started) }
        if let model = export["model"].text { row["model"] = .string(model) }
        for key in ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"] {
            if let count = export[key].integer { row[key] = .number(Double(count)) }
        }
        if let cost = export["estimated_cost"].number { row["estimated_cost_usd"] = .number(cost) }
        row["messages"] = .array(messages.compactMap(importMessage))
        return .object(row)
    }

    private nonisolated static func importMessage(_ message: BotJSON) -> BotJSON? {
        guard let fields = message.fields, let role = fields["role"]?.text, ["user", "assistant", "tool"].contains(role)
        else { return nil }
        var out: [String: BotJSON] = ["role": .string(role), "content": fields["content"] ?? .null]
        if let timestamp = (fields["_ts"] ?? fields["timestamp"])?.number { out["timestamp"] = .number(timestamp) }
        if let calls = fields["tool_calls"], calls.list != nil || calls.text != nil { out["tool_calls"] = calls }
        if let callID = fields["tool_call_id"]?.text { out["tool_call_id"] = .string(callID) }
        if role == "tool", let name = (fields["tool_name"] ?? fields["name"])?.text { out["tool_name"] = .string(name) }
        if role == "assistant" {
            for key in ["reasoning", "reasoning_content"] {
                if let text = fields[key]?.text { out[key] = .string(text) }
            }
        }
        return .object(out)
    }

    nonisolated static func prepare(export: Data, id: String) -> Preparation {
        guard let json = try? JSONDecoder().decode(BotJSON.self, from: export),
              let row = importRow(fromExport: json, id: id) else { return .failed(.unreadable) }
        let count = row["messages"].list?.count ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let encoded = try? encoder.encode(row) else { return .failed(.unreadable) }
        guard count <= messagesPerSession, encoded.count <= bytesPerSession else { return .failed(.oversized) }
        return .ready(Prepared(id: id, encoded: encoded, messageCount: count))
    }

    nonisolated static func body(_ batch: [Prepared], destination: String) -> Data {
        var body = Data(#"{"sessions":["#.utf8)
        for (index, prepared) in batch.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(prepared.encoded)
        }
        body.append(Data(#"],"profile":"#.utf8))
        body.append((try? JSONEncoder().encode(destination)) ?? Data(#""""#.utf8))
        body.append(UInt8(ascii: "}"))
        return body
    }

    /// Whether `batch` fits one import's session, message and request-size limits, counting the
    /// write identity `HermesREST.importSessions` adds to the body.
    nonisolated static func fits(_ batch: [Prepared], destination: String) -> Bool {
        guard batch.count <= sessionsPerImport, batch.reduce(0, { $0 + $1.messageCount }) <= messagesPerImport else { return false }
        let overhead = 32 + destination.utf8.count * 2 + max(0, batch.count - 1)
            + HermesSessionWriteIdentity(expectedRevision: 0).leadingMembers.count
        return batch.reduce(overhead) { $0 + $1.encoded.count } <= bytesPerImport
    }

    /// One chat's export from the webui, converted off the main actor.
    @MainActor
    private static func export(_ id: String, from webui: APIClient) async -> Preparation {
        do {
            let file = try await webui.exportSession(id: id, format: .json)
            return await Task.detached(priority: .userInitiated) { prepare(export: file.data, id: id) }.value
        } catch {
            return .failed(Task.isCancelled ? .notSent : .unreadable)
        }
    }

    /// The host's reasons, at the pin, for a session over its own limits and for a payload over
    /// the request's totals, which falls on whichever session crossed them.
    private static let sessionLimitReasons: Set<String> = [
        "messages exceeds the per-session import limit", "session exceeds the import size limit"
    ]
    private static let totalLimitReasons: Set<String> = [
        "import exceeds the total size limit", "messages exceeds the total import limit"
    ]

    /// One run's outcomes and the import steps that settle them.
    @MainActor
    private final class Attempt {
        let hermes: any BotTransport
        let profiles: [String]
        let total: Int
        let willDispatch: @MainActor (Dispatch) async throws -> Void
        let progress: @MainActor (Int, Int) -> Void
        private(set) var outcomes: [String: Outcome] = [:]
        /// Set when `willDispatch` failed: nothing more may be sent.
        private var stopped = false

        init(hermes: any BotTransport, profiles: [String], total: Int,
             willDispatch: @escaping @MainActor (Dispatch) async throws -> Void,
             progress: @escaping @MainActor (Int, Int) -> Void) {
            self.hermes = hermes
            self.profiles = profiles
            self.total = total
            self.willDispatch = willDispatch
            self.progress = progress
        }

        var canSend: Bool { !stopped && !Task.isCancelled }

        func settle(_ ids: [String], _ outcome: Outcome) {
            guard !ids.isEmpty else { return }
            for id in ids { outcomes[id] = outcome }
            progress(outcomes.count, total)
        }

        /// Rechecks `batch` in every Hermes Profile, then sends what is still missing.
        func importBatch(_ batch: [Prepared], into destination: String) async {
            guard !batch.isEmpty else { return }
            guard canSend else { return settle(batch.map(\.id), .notSent) }
            let locations = await MoveToHermesScan.locate(batch.map(\.id), in: profiles, on: hermes)
            var missing: [Prepared] = []
            for prepared in batch {
                switch locations[prepared.id] {
                case .missing?: missing.append(prepared)
                case .present(let profile)?: settle([prepared.id], .alreadyPresent(profile: profile))
                case .ambiguous(let profiles)?: settle([prepared.id], .ambiguous(profiles: profiles))
                case .unknown?, nil: settle([prepared.id], Task.isCancelled ? .notSent : .unknown)
                }
            }
            await send(missing, into: destination)
        }

        /// Sends one import of `batch`. A 400 or 413 wrote nothing, so the refused chats are
        /// dropped, or the batch halved, and the rest sent again. Any other 4xx refuses the batch;
        /// a 408, a 429, a write fence 409 (`HermesSessionFenceRefusal`, which the next run
        /// relocates) or any other failure leaves it uncertain.
        private func send(_ batch: [Prepared], into destination: String) async {
            guard !batch.isEmpty else { return }
            guard canSend else { return settle(batch.map(\.id), .notSent) }
            do {
                try await willDispatch(Dispatch(destination: destination, ids: batch.map(\.id)))
            } catch {
                stopped = true
                return settle(batch.map(\.id), .notSent)
            }
            do {
                let result = try await hermes.importSessions(body: WebuiSessionTransfer.body(batch, destination: destination))
                let imported = Set(result["imported_ids"].list?.compactMap(\.text) ?? [])
                let skipped = Set(result["skipped_ids"].list?.compactMap(\.text) ?? [])
                for prepared in batch {
                    settle([prepared.id], imported.contains(prepared.id) ? .imported(profile: destination)
                           : skipped.contains(prepared.id) ? .alreadyPresent(profile: destination)
                           : .uncertain(profile: destination))
                }
            } catch let refusal as HermesSessionRefusal {
                await resend(batch, into: destination, after: refusal)
            } catch BotFailure.rejected(413) {
                await split(batch, into: destination)
            } catch BotFailure.rejected(let status) where (400..<500).contains(status) && ![408, 429].contains(status) {
                settle(batch.map(\.id), .rejected(reason: BotFailure.rejected(status).localizedDescription))
            } catch {
                settle(batch.map(\.id), .uncertain(profile: destination))
            }
        }

        /// After a 400: settles every chat the host named and sends the rest. A chat named for
        /// the request's totals isn't at fault, so that batch is halved instead.
        private func resend(_ batch: [Prepared], into destination: String, after refusal: HermesSessionRefusal) async {
            var rest: [Prepared] = []
            var overTotals = false
            for (index, prepared) in batch.enumerated() {
                let entry = refusal.entries.first { $0.sessionID == prepared.id }
                    ?? refusal.entries.first { $0.sessionID == nil && $0.index == index }
                guard let reason = entry?.reason else { rest.append(prepared); continue }
                if WebuiSessionTransfer.totalLimitReasons.contains(reason) {
                    overTotals = true
                    rest.append(prepared)
                } else {
                    settle([prepared.id], WebuiSessionTransfer.sessionLimitReasons.contains(reason) ? .oversized
                           : .rejected(reason: reason))
                }
            }
            if overTotals {
                await split(rest, into: destination)
            } else if rest.count == batch.count {
                // Nothing named matched a chat sent, so nothing can be dropped: report the refusal.
                settle(batch.map(\.id), .rejected(reason: refusal.message))
            } else {
                await send(rest, into: destination)
            }
        }

        /// Sends `batch` as two halves; a single chat too large for any request is oversized.
        private func split(_ batch: [Prepared], into destination: String) async {
            guard batch.count > 1 else { return settle(batch.map(\.id), .oversized) }
            let half = batch.count / 2
            await send(Array(batch[..<half]), into: destination)
            await send(Array(batch[half...]), into: destination)
        }
    }
}
