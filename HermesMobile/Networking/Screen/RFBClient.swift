import CoreGraphics
import Foundation

enum RFBStreamEnd: Error, Equatable {
    case closed(code: Int)
    case silent
}

protocol RFBSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func ping() async throws
    func close()
}

actor RFBClient {
    struct Options {
        var keepalive: Duration = .seconds(25)
        var minimumFrameInterval: Duration = .milliseconds(66)
    }

    private let socket: any RFBSocket
    private let options: Options
    private let onFrame: @Sendable (CGImage) async -> Void
    private let decoder = RFBDecoder()
    private let clock = ContinuousClock()
    private var lastRequest: ContinuousClock.Instant?
    private var awaitingPong = false

    init(socket: any RFBSocket, options: Options = Options(), onFrame: @escaping @Sendable (CGImage) async -> Void) {
        self.socket = socket
        self.options = options
        self.onFrame = onFrame
    }

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

    func send(_ data: Data) async throws {
        try await socket.send(data)
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
        task.cancel(with: .internalServerError, reason: nil)
    }
}
