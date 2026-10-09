import Foundation
import WatchConnectivity
import WatchShared

/// iPhone WCSession host. Decodes watch envelopes and runs them on the broker.
final class PhoneWatchConnectivityHost: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchConnectivityHost()

    private let dispatcher: WatchWireDispatcher
    private let voiceInbox = WatchVoiceNoteFileInbox()

    override private init() {
        let broker = PhoneCompanionBroker(
            epoch: WatchInstallationIdentity.epoch(),
            backend: APIClientWatchPhoneBackend(),
            issuedRunStore: WatchIssuedRunFileStore()
        )
        dispatcher = WatchWireDispatcher(
            service: broker,
            transcribe: { request in
                await broker.sendVoiceNote(request)
            },
            sendPhoto: { request in
                await broker.sendPhoto(request)
            }
        )
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Queues a finished reply for the watch. `transferUserInfo` wakes the
    /// watch app, which posts it as its own notification when Now is not open.
    func deliverReply(body: String, sessionID: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(WatchReplyNotice.userInfo(body: body, sessionID: sessionID))
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let data = message["data"] as? Data else {
            replyHandler(["error": "invalidEnvelope"])
            return
        }
        // The reply has to be invoked on this thread before the method returns.
        // A Task that answers later is dropped: the watch never gets the list
        // and Tasks / Kanban stay on the spinner. Voice notes stay deferred
        // because they wait on a file already handed to this same queue.
        if Self.needsDeferredReply(data) {
            Task {
                let reply = await handle(data)
                replyHandler(["data": reply])
            }
            return
        }
        let payload = ReplyPayload()
        let ready = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            payload.store(await self.handle(data))
            ready.signal()
        }
        let answered: Bool
        if Thread.isMainThread {
            // Pump the main run loop so a hop onto it can finish, without
            // returning from this method before the reply is sent.
            let deadline = Date().addingTimeInterval(30)
            while !payload.isReady, Date() < deadline {
                RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
            }
            answered = payload.isReady
        } else {
            answered = ready.wait(timeout: .now() + 30) == .success
        }
        replyHandler(["data": answered ? payload.load() : Self.readFailedReply()])
    }

    /// Transcription and photo upload wait on work that is already in flight
    /// on this session. Every other read answers before this method returns.
    private static func needsDeferredReply(_ data: Data) -> Bool {
        guard let message = try? JSONDecoder().decode(WatchWireMessage.self, from: data) else {
            return false
        }
        switch message {
        case .transcribe, .transcribeFile, .sendPhoto, .sendPhotoFile:
            return true
        default:
            return false
        }
    }

    private static func readFailedReply() -> Data {
        let failure = WatchWireReply.failure(.uncertain(code: "readFailed"))
        return (try? JSONEncoder().encode(failure)) ?? Data()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let voiceID = (file.metadata?[WatchVoiceNoteWire.fileTransferMetadataKey] as? String)
            .flatMap(UUID.init(uuidString:))
        let photoID = (file.metadata?[WatchPhotoWire.fileTransferMetadataKey] as? String)
            .flatMap(UUID.init(uuidString:))
        guard let transferID = voiceID ?? photoID,
              let data = try? Data(contentsOf: file.fileURL),
              !data.isEmpty
        else {
            return
        }
        let maximum = voiceID != nil
            ? WatchVoiceNoteRequest.maximumAudioBytes
            : WatchPhotoSendRequest.maximumImageBytes
        guard data.count <= maximum else { return }
        Task { await voiceInbox.deposit(transferID: transferID, data: data) }
    }

    private func handle(_ data: Data) async -> Data {
        do {
            let message = try JSONDecoder().decode(WatchWireMessage.self, from: data)
            let resolved = await resolveFileHop(message)
            let reply = await dispatcher.handle(resolved)
            let encoded = try JSONEncoder().encode(reply)
            // A reply past the sendMessage ceiling is discarded with no error
            // on the watch. A small failure still arrives, so the glance can
            // show Try again instead of spinning.
            if encoded.count <= WatchVoiceNoteWire.maximumDeliverableReplyBytes {
                return encoded
            }
            let failure = WatchWireReply.failure(.uncertain(code: "readFailed"))
            return try JSONEncoder().encode(failure)
        } catch {
            let failure = WatchWireReply.failure(.invalidEnvelope(code: "decodeFailed"))
            return (try? JSONEncoder().encode(failure)) ?? Data()
        }
    }

    private func resolveFileHop(_ message: WatchWireMessage) async -> WatchWireMessage {
        switch message {
        case .transcribeFile(let ref):
            do {
                let audio = try await takeTransferredFile(transferID: ref.transferID)
                return .transcribe(try ref.makeRequest(audio: audio))
            } catch {
                return message
            }
        case .sendPhotoFile(let ref):
            do {
                let image = try await takeTransferredFile(transferID: ref.transferID)
                return .sendPhoto(try ref.makeRequest(image: image))
            } catch {
                return message
            }
        default:
            return message
        }
    }

    private func takeTransferredFile(transferID: UUID) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.voiceInbox.take(transferID: transferID) }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                await self.voiceInbox.fail(
                    transferID: transferID,
                    error: WatchCompanionError.phoneUnavailable
                )
                throw WatchCompanionError.phoneUnavailable
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// The session thread and the worker that builds a reply share this buffer.
private final class ReplyPayload: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ready = false

    func store(_ data: Data) {
        lock.lock()
        self.data = data
        ready = true
        lock.unlock()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
