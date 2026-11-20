import Foundation

@MainActor final class BotClient: BotTransport {
    private var gateway: HermesGateway
    private let profile: String?
    let consumerID: Int
    let http: HermesConnection
    private var attempt = 0
    private var imageUploads: [UUID: Task<BotUploadedImage, Error>] = [:]
    private var artifactTasks: [UUID: Task<Data, Error>] = [:]
    var replayEpoch: String? { gateway.replayEpoch }
    var speaksCanonicalProtocol: Bool { gateway.speaksCanonicalProtocol }
    var serverVersion: String? { http.serverVersion }
    var serverInstallID: String? { http.serverInstallID }
    var unavailableMethods: Set<String> { http.unavailableMethods }
    var lastAttempt: HermesAttemptRecord? { http.lastAttempt }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    convenience init(saved connection: BotConnection, server: URL, profile: String? = nil) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server), profile: profile)
    }

    convenience init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral,
                     rpcDeadline: Duration = .seconds(30), heartbeatInterval: Duration = .seconds(15),
                     socketFactory: ((URLRequest) -> any BotSocket)? = nil) {
        self.init(http: HermesConnection(connection: connection, configuration: configuration, gateway: .init(
            rpcDeadline: rpcDeadline, heartbeatInterval: heartbeatInterval, socketFactory: socketFactory)))
    }

    init(http: HermesConnection, profile: String? = nil) {
        self.http = http
        self.profile = profile
        gateway = http.gateway
        consumerID = http.makeConsumerID()
    }

    func connect() async throws {
        close()
        let attempt = self.attempt
        do {
            if let profile {
                try await http.signIn()
                guard attempt == self.attempt else { throw BotFailure.stale }
                gateway = http.gateway(profile: profile)
            }
            try await gateway.join(self)
        }
        catch { throw attempt == self.attempt ? error : BotFailure.stale }
        guard attempt == self.attempt else { throw BotFailure.stale }
        guard !Task.isCancelled else { close(); throw BotFailure.stale }
    }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        try await gateway.send(call, for: consumerID, validateDispatch: validateDispatch)
    }

    func respond(toRequest id: String, result: BotJSON, validateDispatch: (() throws -> Void)?) async throws {
        try await gateway.respond(toRequest: id, result: result, for: consumerID, validateDispatch: validateDispatch)
    }

    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data {
        guard context.connectionID == http.connection.id, gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let request = try HermesREST.downloadArtifact(path: path, profile: context.profile, sessionID: context.sessionID)
            .request(base: http.connection.address)
        let id = UUID()
        let http = self.http
        let task = Task {
            try await http.authorized(request, validateDispatch: { try self.checkOwner(attempt) }) { request, session in
                try await BotArtifactDownload.data(session: session, request: request, limit: limit, allowsEmpty: limit == nil)
            }
        }
        artifactTasks[id] = task
        defer { artifactTasks[id] = nil }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try checkOwner(attempt)
            return data
        } onCancel: { task.cancel() }
    }

    func keepPlatformNote(profile: String) async {
        await http.keepPlatformNote(profile: profile)
    }

    func deleteProfile(_ name: String) async throws {
        guard gateway.isAttached(consumerID), BotProfileName.isValid(name) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.deleteProfile(name: name), validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard (try? JSONDecoder().decode(BotJSON.self, from: data))?["ok"].flag == true else { throw BotFailure.unsupported }
    }

    func currentProfile() async throws -> String {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.profilesActive, validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let profile = (try? JSONDecoder().decode(BotJSON.self, from: data))?["current"].text,
              !profile.isEmpty else { throw BotFailure.unsupported }
        return profile
    }

    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]? {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data: Data
        do {
            data = try await http.data(.sessionMessages(key: key, profile: profile, offset: offset),
                                       validateDispatch: { try self.checkOwner(attempt) })
        } catch BotFailure.rejected(404) {
            try checkOwner(attempt)
            return nil
        }
        try checkOwner(attempt)
        guard let messages = (try? JSONDecoder().decode(BotJSON.self, from: data))?["messages"].list else {
            throw BotFailure.unsupported
        }
        return messages
    }

    func speech(text: String, profile: String) async throws -> Data {
        let attempt = self.attempt
        let request = try HermesREST.speak(text: text, profile: profile).request(base: http.connection.address)
        return try await http.authorized(request, deadline: .provisioning,
                                         validateDispatch: { try self.checkOwner(attempt) }) { request, session in
            try Self.speechAudio(fromReply: try await BotArtifactDownload.data(session: session, request: request))
        }
    }

    nonisolated static func speechAudio(fromReply body: Data) throws -> Data {
        guard let url = (try? JSONDecoder().decode(BotJSON.self, from: body))?["data_url"].text,
              url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
              let audio = Data(base64Encoded: String(url[url.index(after: comma)...])), !audio.isEmpty
        else { throw BotFailure.unsupported }
        return audio
    }

    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionList(profile: profile, offset: offset, archived: archived),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let page = try? JSONDecoder().decode(HermesSessionPage.self, from: data) else { throw BotFailure.unsupported }
        return page
    }

    func scheduledSessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionList(profile: profile, offset: offset, archived: archived, scheduled: true),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let page = try? JSONDecoder().decode(HermesSessionPage.self, from: data) else { throw BotFailure.unsupported }
        return page
    }

    func archivedSessionCount(profile: String) async throws -> Int {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionList(profile: profile, offset: 0, archived: true, limit: 0),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let total = (try? JSONDecoder().decode(HermesSessionPage.self, from: data))?.total else {
            throw BotFailure.unsupported
        }
        return total
    }

    func searchScheduledSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionSearch(query: query, profile: profile, limit: limit, scheduled: true),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let search = try? JSONDecoder().decode(HermesSessionSearch.self, from: data) else { throw BotFailure.unsupported }
        return search.results
    }

    func sessionScanPage(profile: String, offset: Int) async throws -> HermesScanPage {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionScan(profile: profile, offset: offset),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let page = try? JSONDecoder().decode(HermesScanPage.self, from: data) else { throw BotFailure.unsupported }
        return page
    }

    @discardableResult
    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let identity = try await writeIdentity(key: key, profile: profile, attempt: attempt)
        let reply = try await http.reply(.updateSession(key: key, profile: profile, change: change, identity: identity),
                                         validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        guard reply.status == 200 else {
            if reply.status == 400, let detail = body?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                throw HermesSessionRefusal(message: detail)
            }
            if let refusal = HermesSessionFenceRefusal(detail: body?["detail"].text) { throw refusal }
            throw BotFailure.rejected(reply.status)
        }
        return body?["title"].text
    }

    private func writeIdentity(key: String, profile: String, attempt: Int) async throws -> HermesSessionWriteIdentity? {
        let reply = try await http.reply(.sessionMutationSnapshot(key: key, profile: profile),
                                         validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        switch reply.status {
        case 200:
            guard body?["exists"] != .bool(false) else { throw BotFailure.rejected(404) }
            guard let revision = body?["runtime_revision"].integer, revision >= 0 else { throw BotFailure.unsupported }
            return HermesSessionWriteIdentity(expectedRevision: revision)
        case 404 where body?["detail"].text?.hasPrefix("No such API endpoint") == true
            || body?["error"].text?.hasPrefix("Headless backend") == true:
            return nil
        default:
            throw BotFailure.rejected(reply.status)
        }
    }

    func exportSession(key: String, profile: String) async throws -> Data {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionExport(key: key, profile: profile), deadline: .provisioning,
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        return data
    }

    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data: Data
        do {
            data = try await http.data(.sessionRow(key: key, profile: profile), validateDispatch: { try self.checkOwner(attempt) })
        } catch BotFailure.rejected(404) {
            try checkOwner(attempt)
            return nil
        }
        try checkOwner(attempt)
        guard let row = try? JSONDecoder().decode(BotJSON.self, from: data), row.fields != nil else { throw BotFailure.unsupported }
        return row
    }

    func importSessions(body: Data) async throws -> BotJSON {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let reply = try await http.reply(.importSessions(body: body, identity: HermesSessionWriteIdentity(expectedRevision: 0)),
                                         deadline: .provisioning,
                                         validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        guard reply.status == 200 else {
            let entries = (body?["detail"]["errors"].list ?? []).compactMap { error -> HermesSessionRefusal.Entry? in
                guard let index = error["index"].integer, let reason = error["error"].text else { return nil }
                return HermesSessionRefusal.Entry(index: index, sessionID: error["session_id"].text, reason: reason)
            }
            let detail = body?["detail"].text ?? entries.first?.reason
            if reply.status == 400, let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                throw HermesSessionRefusal(message: detail, entries: entries)
            }
            if reply.status == 409, let refusal = HermesSessionFenceRefusal(detail: body?["detail"].text) { throw refusal }
            throw BotFailure.rejected(reply.status)
        }
        guard let body, body.fields != nil else { throw BotFailure.unsupported }
        return body
    }

    func searchSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.sessionSearch(query: query, profile: profile, limit: limit),
                                       validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard let search = try? JSONDecoder().decode(HermesSessionSearch.self, from: data) else { throw BotFailure.unsupported }
        return search.results
    }

    var attachedRuntimes: Set<String> { http.attachedRuntimes }
    func release(profile: String, sessionID: String) { gateway.release(consumerID, from: .init(profile: profile, id: sessionID)) }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> BotUploadedImage {
        guard context.connectionID == http.connection.id, gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let id = UUID()
        let http = self.http
        let task = Task {
            try await BotAttachmentUpload.image(data: data, filename: filename, profile: context.profile, via: http,
                                                validateDispatch: { try self.checkOwner(attempt) })
        }
        imageUploads[id] = task
        defer { imageUploads[id] = nil }
        return try await withTaskCancellationHandler {
            let image = try await task.value
            try checkOwner(attempt)
            return image
        } onCancel: { task.cancel() }
    }

    private func checkOwner(_ attempt: Int) throws {
        guard attempt == self.attempt, !Task.isCancelled else { throw BotFailure.stale }
    }

    func close() {
        endLocalWork()
        gateway.leave(self)
    }

    func socketEnded(_ error: Error) {
        endLocalWork()
        onDisconnect?(error)
    }

    private func endLocalWork() {
        attempt += 1
        for task in imageUploads.values { task.cancel() }
        imageUploads.removeAll()
        for task in artifactTasks.values { task.cancel() }
        artifactTasks.removeAll()
    }
}
