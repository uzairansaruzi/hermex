import CoreGraphics
import Foundation

/// How a stream ended, for its owner to decide what comes next.
enum RFBStreamEnd: Error, Equatable {
    /// The other end closed with this WebSocket code. Stock hosts send `4000` control taken,
    /// `4001` screen gone, `4401` bad ticket and `1003` protocol error.
    case closed(code: Int)
    /// A ping went a whole keepalive period without its pong or any frame.
    case silent
}

/// The socket `RFBClient` reads. Production wraps `URLSessionWebSocketTask`; tests script one.
protocol RFBSocket: Sendable {
    /// One binary frame's bytes. Throws `RFBStreamEnd.closed` when the other end closes, and
    /// `BotFailure` for a refused upgrade.
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    /// Sends one ping frame and returns when its pong arrives.
    func ping() async throws
    func close()
}

/// One screen stream: a socket and the decoder reading it. Frames reach `onFrame` off the main
/// actor. It waits for `onFrame` before asking for the next update, so one frame is ever in flight
/// and a slow phone slows the server rather than filling a buffer. `run` returns only by throwing.
///
/// Knows nothing about Hermes: `ScreenSession` hands it a socket opened with a fresh ticket.
actor RFBClient {
    struct Options {
        /// Cloudflare closes a quiet socket at about 100 s, and the bridge closes on any text
        /// frame, so this sends protocol pings, never the gateway's JSON heartbeat.
        var keepalive: Duration = .seconds(25)
        /// At most this often an update is requested: enough for a desktop, and it bounds the
        /// decoding a busy screen can cause.
        var minimumFrameInterval: Duration = .milliseconds(66)
    }

    private let socket: any RFBSocket
    private let options: Options
    private let onFrame: @Sendable (CGImage) async -> Void
    private let decoder = RFBDecoder()
    private let clock = ContinuousClock()
    private var lastRequest: ContinuousClock.Instant?
    /// A ping went out and neither its pong nor a frame has arrived since.
    private var awaitingPong = false

    init(socket: any RFBSocket, options: Options = Options(), onFrame: @escaping @Sendable (CGImage) async -> Void) {
        self.socket = socket
        self.options = options
        self.onFrame = onFrame
    }

    /// Reads until the stream ends, then throws why. Cancelling it ends the stream too. Either
    /// way the socket closes, which is also what wakes a read in flight.
    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.read() }
            group.addTask { try await self.keepAlive() }
            defer {
                socket.close()
                group.cancelAll()
            }
            try await group.next()
        }
    }

    private func read() async throws {
        while true {
            try Task.checkCancellation()
            let chunk = try await socket.receive()
            awaitingPong = false
            for output in try decoder.feed(chunk) {
                switch output {
                case .send(let data): try await socket.send(data)
                case .updateComplete: try await finishUpdate()
                }
            }
        }
    }

    private func finishUpdate() async throws {
        if let image = decoder.snapshot() { await onFrame(image) }
        if let lastRequest {
            let wait = options.minimumFrameInterval - lastRequest.duration(to: clock.now)
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastRequest = clock.now
        try await socket.send(decoder.updateRequest())
    }

    private func keepAlive() async throws {
        while true {
            try await Task.sleep(for: options.keepalive)
            guard !awaitingPong else { throw RFBStreamEnd.silent }
            awaitingPong = true
            // Not awaited here: a pong can take as long as the period allows. A ping that fails
            // never clears the flag, so the next tick ends the stream.
            let socket = socket
            Task { [weak self] in
                guard (try? await socket.ping()) != nil else { return }
                await self?.notePong()
            }
        }
    }

    private func notePong() {
        awaitingPong = false
    }
}

/// The production socket.
struct NativeRFBSocket: RFBSocket {
    let task: URLSessionWebSocketTask

    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            case .string: throw RFBFailure.malformed
            @unknown default: throw RFBFailure.malformed
            }
        } catch let failure as RFBFailure {
            throw failure
        } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, let refusal = BotFailure(upgradeStatus: status) {
                throw refusal
            }
            let code = task.closeCode.rawValue
            if code != URLSessionWebSocketTask.CloseCode.invalid.rawValue { throw RFBStreamEnd.closed(code: code) }
            throw error
        }
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func ping() async throws {
        let task = task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
