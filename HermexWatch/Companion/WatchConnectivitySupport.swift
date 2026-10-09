import Foundation
import UserNotifications
import WatchConnectivity
import WatchShared
import HermexWatchRoot

final class WatchSessionActivator: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionActivator()

    private let lock = NSLock()
    private var fileWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Invoked on activation completion and on every reachability change so the
    /// app can refresh the model. WCSession delivers delegate calls on the main
    /// queue, so this is a plain `@Sendable` closure the app hops to `@MainActor`.
    var reachabilityChanged: (@Sendable (Bool) -> Void)?
    /// A finished reply the phone pushed over WatchConnectivity.
    var replyArrived: (@Sendable (String) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func transferVoiceFile(at url: URL, transferID: UUID) async throws {
        try await transferFile(
            at: url,
            transferID: transferID,
            metadataKey: WatchVoiceNoteWire.fileTransferMetadataKey
        )
    }

    func transferPhotoFile(at url: URL, transferID: UUID) async throws {
        try await transferFile(
            at: url,
            transferID: transferID,
            metadataKey: WatchPhotoWire.fileTransferMetadataKey
        )
    }

    private func transferFile(at url: URL, transferID: UUID, metadataKey: String) async throws {
        guard WCSession.isSupported() else {
            throw WatchCompanionError.phoneUnavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            fileWaiters[transferID] = continuation
            lock.unlock()
            _ = WCSession.default.transferFile(
                url,
                metadata: [metadataKey: transferID.uuidString]
            )
            // A quiet phone never calls didFinish. Sending must be able to fail.
            DispatchQueue.global().asyncAfter(deadline: .now() + WCSessionTransport.mediaTransferTimeout) { [weak self] in
                self?.finishTransfer(transferID, error: WatchCompanionError.phoneUnavailable)
            }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // On (re)activation, drive a refresh so a reconnect after backgrounding
        // re-attaches the model instead of staying on a stale state. If the
        // phone is already reachable this kicks the registry reload; if not, the
        // model presents an honest waiting state.
        guard activationState == .activated, error == nil else { return }
        reachabilityChanged?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let body = WatchReplyNotice.body(in: userInfo) else { return }
        replyArrived?(body)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        // The phone became reachable or quiet. The model decides which: reachable
        // → reload registry; unreachable → honest disconnected state (not a stale
        // ready, and not "Set up on iPhone" if the companion is installed).
        reachabilityChanged?(session.isReachable)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let raw = fileTransfer.file.metadata?[WatchVoiceNoteWire.fileTransferMetadataKey] as? String
            ?? fileTransfer.file.metadata?[WatchPhotoWire.fileTransferMetadataKey] as? String
        guard let raw, let transferID = UUID(uuidString: raw) else {
            return
        }
        finishTransfer(transferID, error: error)
    }

    private func finishTransfer(_ transferID: UUID, error: Error?) {
        lock.lock()
        let waiter = fileWaiters.removeValue(forKey: transferID)
        lock.unlock()
        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume()
        }
    }
}

struct WatchConnectivitySessionLink: WatchCompanionLinking {
    var isCompanionAvailable: Bool {
        WCSession.isSupported() && WCSession.default.isCompanionAppInstalled
    }

    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    var phoneNeedsUnlockAfterReboot: Bool {
        WCSession.isSupported() && WCSession.default.iOSDeviceNeedsUnlockAfterRebootForReachability
    }

    func makeService() -> any WatchCompanionServicing {
        WatchWireClient(transport: WCSessionTransport())
    }

    func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey> {
        try await WatchWireClient(transport: WCSessionTransport()).sendVoiceNote(request)
    }

    func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey> {
        try await WatchWireClient(transport: WCSessionTransport()).sendPhoto(request)
    }
}

/// One `sendMessage` at a time. A second call while the first is still
/// waiting is dropped by WatchConnectivity and never answers.
private actor WatchMessageSerializer {
    static let shared = WatchMessageSerializer()

    func run(_ body: @Sendable () async throws -> WatchWireReply) async throws -> WatchWireReply {
        try await body()
    }
}

struct WCSessionTransport: WatchWireTransporting {
    func send(_ message: WatchWireMessage) async throws -> WatchWireReply {
        guard WCSession.isSupported() else {
            throw WatchCompanionError.phoneUnavailable
        }
        return try await WatchMessageSerializer.shared.run {
            try await self.sendSerialized(message)
        }
    }

    private func sendSerialized(_ message: WatchWireMessage) async throws -> WatchWireReply {
        // Do not refuse just because isReachable is false. sendMessage launches
        // the iPhone app when it is not in the foreground, including while the
        // phone is locked, as long as it was unlocked once after boot.
        if case .transcribe(let request) = message, WatchVoiceNoteWire.requiresFileTransfer(request) {
            return try await sendTranscribeViaFile(request)
        }
        if case .sendPhoto(let request) = message, WatchPhotoWire.requiresFileTransfer(request) {
            return try await sendPhotoViaFile(request)
        }
        return try await sendInline(message)
    }

    private func sendTranscribeViaFile(_ request: WatchVoiceNoteRequest) async throws -> WatchWireReply {
        let transferID = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(transferID.uuidString).m4a")
        try request.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await WatchSessionActivator.shared.transferVoiceFile(at: url, transferID: transferID)
        return try await sendInline(.transcribeFile(try request.fileRef(transferID: transferID)))
    }

    private func sendPhotoViaFile(_ request: WatchPhotoSendRequest) async throws -> WatchWireReply {
        let transferID = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(transferID.uuidString).jpg")
        try request.image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await WatchSessionActivator.shared.transferPhotoFile(at: url, transferID: transferID)
        return try await sendInline(.sendPhotoFile(try request.fileRef(transferID: transferID)))
    }

    /// The registry read gates "Connecting". WatchConnectivity can sit on a
    /// message to a phone that just went quiet without calling either handler,
    /// so this one read gives up and lets the model show first-run copy.
    static let registryReplyTimeout: TimeInterval = 10
    /// A reachable phone that accepts a read and never replies used to leave
    /// Tasks and Kanban on a spinner. Voice notes and photos still wait: they
    /// block on transcription and upload.
    static let reachableReplyTimeout: TimeInterval = 40
    /// Voice notes and photos used to wait forever for the file hop and the
    /// phone's reply. Three minutes covers a long clip, then Sending can fail.
    static let mediaTransferTimeout: TimeInterval = 60
    static let mediaReplyTimeout: TimeInterval = 180

    private func replyTimeout(for message: WatchWireMessage) -> TimeInterval? {
        switch message {
        case .transcribe, .transcribeFile, .sendPhoto, .sendPhotoFile:
            return Self.mediaReplyTimeout
        case .registry:
            return Self.registryReplyTimeout
        default:
            return WCSession.default.isReachable ? Self.reachableReplyTimeout : Self.registryReplyTimeout
        }
    }

    private func sendInline(_ message: WatchWireMessage) async throws -> WatchWireReply {
        let payload = try JSONEncoder().encode(message)
        // A quiet phone used to sit forever on sendMessage. Give a locked phone
        // time to wake Hermex, then give up so the wrist can keep its last data.
        // The timeout is armed before sendMessage, and sendMessage itself runs
        // off the main thread: a call that blocks would otherwise pin the watch
        // UI on the spinner with the timeout still unscheduled.
        let timeout = replyTimeout(for: message)
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ReplyOnce(continuation)
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    reply.resume(.failure(WatchCompanionError.phoneUnavailable))
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                WCSession.default.sendMessage(
                    ["data": payload],
                    replyHandler: { message in
                        guard let data = message["data"] as? Data else {
                            reply.resume(.failure(WatchCompanionError.backend(.invalidResponse)))
                            return
                        }
                        reply.resume(Result { try JSONDecoder().decode(WatchWireReply.self, from: data) })
                    },
                    errorHandler: { error in
                        reply.resume(.failure(error))
                    }
                )
            }
        }
    }
}

/// Posts one reply as a watch notification. Authorization is requested while
/// the app is open, so a later background delivery can present it.
enum WatchReplyNotifier {
    static func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Hermex"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "hermex-reply-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Resumes a continuation at most once, whichever of reply, error or timeout
/// arrives first.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchWireReply, Error>?

    init(_ continuation: CheckedContinuation<WatchWireReply, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<WatchWireReply, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
