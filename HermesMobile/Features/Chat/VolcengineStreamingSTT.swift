import Foundation
import Compression
import OSLog

/// Volcengine (ByteDance/Doubao) streaming ASR client.
/// Uses WebSocket with a custom binary protocol to stream PCM audio frames
/// and receive real-time partial transcription results.
///
/// Protocol: wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
/// Docs: https://www.volcengine.com/docs/6561/1354869
@MainActor
final class VolcengineStreamingSTT: NSObject {
    enum State {
        case idle
        case connecting
        case streaming
        /// The last audio packet has been sent and we are waiting for the server's
        /// final result. The server closes the socket itself once it finalizes, so a
        /// close/read error in this state is the expected end of a dictation, not a fault.
        case finishing
        case finished
        case failed(Error)
    }

    struct Configuration {
        let apiKey: String
        let resourceId: String
        var language: String = "zh-CN"
        /// VAD end-of-speech silence threshold in ms. Default 800ms.
        var endWindowSize: Int = 800
        /// Hot words for better recognition of domain terms.
        var hotwords: [String] = []

        static let defaultResourceId = "volc.seedasr.sauc.duration"
    }

    private(set) var state: State = .idle
    private(set) var currentText: String = ""

    /// Called on every partial transcript update (main actor).
    var onPartialResult: ((String) -> Void)?
    /// Called when a sentence is finalized (definite=true).
    var onFinalResult: ((String) -> Void)?
    /// Called when the session ends (either normally or with error).
    var onCompleted: ((Result<String, Error>) -> Void)?
    /// Called when WebSocket is connected and ready to receive audio frames.
    var onReady: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let connectId = UUID().uuidString
    private let logger = Logger(subsystem: "com.gyliu.hermex", category: "VolcengineSTT")
    private var configuration: Configuration?
    private var hasReceivedResult = false

    // MARK: - Diagnostics
    // These counters are surfaced in failure messages so a single screenshot pins down
    // which stage broke, instead of guessing between capture / transport / parsing.
    private var framesSent = 0
    private var bytesSent = 0
    /// Tap produced audio but the state gate rejected it (e.g. WebSocket not ready yet).
    private var framesDropped = 0
    private var packetsReceived = 0
    private var payloadsParsed = 0
    private var parseFailures = 0
    private var lastServerMessageType: UInt8?

    var diagnosticSummary: String {
        let lastType = lastServerMessageType.map { String(format: "0x%02X", $0) } ?? "none"
        return "sent=\(framesSent)f/\(bytesSent)B dropped=\(framesDropped) recv=\(packetsReceived) parsed=\(payloadsParsed) parseFail=\(parseFailures) lastType=\(lastType)"
    }

    // MARK: - Public API

    func start(configuration: Configuration) {
        guard case .idle = state else {
            logger.warning("start() called in non-idle state")
            return
        }

        self.configuration = configuration
        self.currentText = ""
        self.hasReceivedResult = false
        framesSent = 0
        bytesSent = 0
        framesDropped = 0
        packetsReceived = 0
        payloadsParsed = 0
        parseFailures = 0
        lastServerMessageType = nil
        state = .connecting

        // Build URL with auth params as query string (fallback for iOS URLSession header issues)
        var components = URLComponents(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        components.queryItems = [
            URLQueryItem(name: "X-Api-Key", value: configuration.apiKey),
            URLQueryItem(name: "X-Api-Resource-Id", value: configuration.resourceId),
            URLQueryItem(name: "X-Api-Connect-Id", value: connectId),
            URLQueryItem(name: "X-Api-Request-Id", value: UUID().uuidString),
            URLQueryItem(name: "X-Api-Sequence", value: "-1")
        ]

        var request = URLRequest(url: components.url!)
        // Also set as headers (belt and suspenders)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = 15

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        logger.info("WebSocket connecting to Volcengine ASR, connectId=\(self.connectId)")
    }

    /// Send a PCM audio frame (16kHz, mono, 16-bit, ~200ms recommended).
    func sendAudioFrame(_ pcmData: Data) {
        guard case .streaming = state else {
            // Counted rather than silently ignored: a high drop count means the mic was
            // capturing before the socket was ready, which is invisible otherwise.
            framesDropped += 1
            return
        }
        framesSent += 1
        bytesSent += pcmData.count
        let message = buildAudioOnlyMessage(pcmData)
        webSocketTask?.send(.data(message)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.logger.error("Failed to send audio frame: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Signal end of audio input. Server will finalize remaining text.
    func finishAudio() {
        guard case .streaming = state else { return }
        let message = buildLastAudioMessage()
        // Flip state before sending: the server may close the socket as soon as it
        // finalizes, and the close must not be reported as a connection failure.
        state = .finishing
        webSocketTask?.send(.data(message)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.logger.error("Failed to send last frame: \(error.localizedDescription)")
                }
            }
        }
        logger.info("Sent last audio frame (negative packet)")
    }

    func cancel() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .idle
        logger.info("Cancelled Volcengine STT session")
    }

    // MARK: - Binary Protocol

    /// Build the first message: full client request with JSON config.
    private func buildFullClientRequest() -> Data {
        guard let configuration else { return Data() }

        var payload: [String: Any] = [
            "user": [
                "uid": "hermex-ios",
                "platform": "iOS"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "result_type": "full",
                "end_window_size": configuration.endWindowSize
            ] as [String: Any]
        ]

        // Add hotwords if configured
        if !configuration.hotwords.isEmpty {
            let hotwordList = configuration.hotwords.map { ["word": $0] }
            let contextJSON = try? JSONSerialization.data(
                withJSONObject: ["hotwords": hotwordList]
            )
            if let contextJSON, let contextStr = String(data: contextJSON, encoding: .utf8) {
                var requestDict = payload["request"] as? [String: Any] ?? [:]
                requestDict["corpus"] = ["context": contextStr]
                payload["request"] = requestDict
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return Data()
        }

        // Header: version=1, headerSize=1, msgType=0001(full client req),
        // flags=0000, serialization=0001(JSON), compression=0000(none), reserved=0
        let header: [UInt8] = [
            0x11, // version=1 | headerSize=1
            0x10, // msgType=0001 | flags=0000
            0x10, // serialization=0001(JSON) | compression=0000(none)
            0x00  // reserved
        ]

        var message = Data(header)
        var payloadSize = UInt32(jsonData.count).bigEndian
        message.append(Data(bytes: &payloadSize, count: 4))
        message.append(jsonData)
        return message
    }

    /// Build an audio-only message (mid-stream audio frames).
    private func buildAudioOnlyMessage(_ pcmData: Data) -> Data {
        // Header: version=1, headerSize=1, msgType=0010(audio only),
        // flags=0000, serialization=0000(none), compression=0000(none), reserved=0
        let header: [UInt8] = [
            0x11, // version=1 | headerSize=1
            0x20, // msgType=0010 | flags=0000
            0x00, // serialization=0000 | compression=0000
            0x00  // reserved
        ]

        var message = Data(header)
        var payloadSize = UInt32(pcmData.count).bigEndian
        message.append(Data(bytes: &payloadSize, count: 4))
        message.append(pcmData)
        return message
    }

    /// Build the last audio message (negative packet, signals end of input).
    private func buildLastAudioMessage() -> Data {
        // Header: version=1, headerSize=1, msgType=0010(audio only),
        // flags=0010(last packet, no sequence), serialization=0000, compression=0000
        let header: [UInt8] = [
            0x11, // version=1 | headerSize=1
            0x22, // msgType=0010 | flags=0010(last packet)
            0x00, // serialization=0000 | compression=0000
            0x00  // reserved
        ]

        var message = Data(header)
        // Empty payload
        var payloadSize = UInt32(0).bigEndian
        message.append(Data(bytes: &payloadSize, count: 4))
        return message
    }

    // MARK: - Response Parsing

    /// First bytes of a frame as hex, for diagnosing header/offset mistakes from a log line.
    private static func hexPrefix(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func parseServerResponse(_ data: Data) {
        packetsReceived += 1
        guard data.count >= 4 else {
            logger.warning("Response too short: \(data.count) bytes")
            parseFailures += 1
            return
        }

        let byte1 = data[1]
        let msgType = (byte1 >> 4) & 0x0F
        lastServerMessageType = msgType

        if msgType == 0x0F {
            // Error message from server
            parseErrorResponse(data)
            return
        }

        guard msgType == 0x09 else {
            logger.debug("Ignoring message type: 0x\(String(format: "%02X", msgType))")
            return
        }

        // Full server response layout:
        //   header (headerSize*4 B) | [sequence number 4B] | payload size 4B | payload
        // Flags 0b0001 / 0b0011 mean the four bytes right after the header are a sequence
        // number. Sequence numbers are small integers, so mis-reading one as the payload
        // size yields a tiny length that still passes the bounds check and produces a
        // garbage slice — the parseFail == recv signature measured on device.
        let headerSize = max(Int(data[0] & 0x0F) * 4, 4)
        let flags = data[1] & 0x0F
        let hasSequenceNumber = (flags == 0x01 || flags == 0x03)
        var cursor = headerSize + (hasSequenceNumber ? 4 : 0)

        guard data.count >= cursor + 4 else {
            parseFailures += 1
            logger.error("Response too short for payload size: \(data.count)B cursor=\(cursor) hex=\(Self.hexPrefix(data))")
            return
        }
        let payloadSize = Int(data.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        })
        cursor += 4

        guard payloadSize > 0, data.count >= cursor + payloadSize else {
            parseFailures += 1
            logger.error("Incomplete payload: declared \(payloadSize)B, have \(data.count - cursor)B hex=\(Self.hexPrefix(data))")
            return
        }

        let payloadData = data.subdata(in: cursor..<(cursor + payloadSize))

        // Check if payload is gzip compressed
        let byte2 = data[2]
        let compression = byte2 & 0x0F
        let jsonData: Data
        if compression == 0x01 {
            // Gzip — decompress
            jsonData = (try? decompressGzip(payloadData)) ?? payloadData
        } else {
            jsonData = payloadData
        }

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            parseFailures += 1
            let preview = String(data: jsonData.prefix(160), encoding: .utf8) ?? "<non-utf8>"
            logger.error("Payload is not JSON: \(preview) hex=\(Self.hexPrefix(data))")
            return
        }
        payloadsParsed += 1

        // The acknowledgement of the full client request carries no result yet, so a
        // missing result field is a normal early packet rather than a parsing fault.
        guard let result = json["result"] as? [String: Any],
              let text = result["text"] as? String
        else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hasReceivedResult = true
            self.currentText = text
            self.onPartialResult?(text)

            // Check for definite (finalized) utterances
            if let utterances = result["utterances"] as? [[String: Any]] {
                for utterance in utterances {
                    if let definite = utterance["definite"] as? Bool, definite,
                       let sentenceText = utterance["text"] as? String {
                        self.onFinalResult?(sentenceText)
                    }
                }
            }
        }
    }

    private func parseErrorResponse(_ data: Data) {
        guard data.count >= 12 else { return }
        let errorCode = data.subdata(in: 4..<8).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        let msgSize = data.subdata(in: 8..<12).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        var errorMsg = "Unknown error"
        if data.count >= 12 + Int(msgSize) {
            errorMsg = String(data: data.subdata(in: 12..<(12 + Int(msgSize))), encoding: .utf8) ?? errorMsg
        }

        logger.error("Volcengine ASR error: code=\(errorCode), msg=\(errorMsg)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let error = VolcengineSTTError.serverError(code: Int(errorCode), message: errorMsg)
            self.state = .failed(error)
            self.onCompleted?(.failure(error))
        }
    }

    private func decompressGzip(_ data: Data) throws -> Data {
        // We send compression=0x00 (none) in our requests, so the server
        // should mirror that and respond uncompressed. This is a safety fallback.
        // Use Apple's Compression framework for decompression.
        let dstSize = data.count * 8 // generous output buffer
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dstBuffer.deallocate() }

        let srcSize = data.count
        let decodedSize = data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                dstBuffer, dstSize,
                srcPtr, srcSize,
                nil, COMPRESSION_ZLIB
            )
        }

        guard decodedSize > 0 else { return data }
        return Data(bytes: dstBuffer, count: decodedSize)
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.parseServerResponse(data)
                    case .string(let string):
                        self.logger.debug("Received text message (unexpected): \(string.prefix(100))")
                    @unknown default:
                        break
                    }
                    // Continue receiving
                    self.startReceiving()
                case .failure(let error):
                    if case .streaming = self.state {
                        self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                        self.state = .failed(error)
                        self.onCompleted?(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Connection Lifecycle

    private func handleConnected() {
        logger.info("WebSocket connected, sending full client request")
        let fullRequest = buildFullClientRequest()
        webSocketTask?.send(.data(fullRequest)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.logger.error("Failed to send full client request: \(error.localizedDescription)")
                    self.state = .failed(error)
                    self.onCompleted?(.failure(error))
                } else {
                    self.state = .streaming
                    self.startReceiving()
                    self.onReady?()
                    self.logger.info("Volcengine STT streaming started")
                }
            }
        }
    }

    private func handleDisconnected(error: Error?) {
        switch state {
        case .finishing:
            // The server closes the socket itself after finalizing, so a close here is the
            // expected end of dictation — but only report success if a transcript actually
            // arrived. Reporting success unconditionally hides real failures as an empty result.
            if hasReceivedResult {
                state = .finished
                onCompleted?(.success(currentText))
            } else {
                let reason = "no transcript received before close — \(diagnosticSummary)"
                logger.error("\(reason)")
                let wrappedError = VolcengineSTTError.connectionFailed(reason)
                state = .failed(wrappedError)
                onCompleted?(.failure(wrappedError))
            }
        case .streaming, .connecting:
            if let error {
                let nsError = error as NSError
                let detailedMessage = "Volcengine WS failed: \(nsError.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)] \(diagnosticSummary)"
                logger.error("\(detailedMessage)")
                let wrappedError = VolcengineSTTError.connectionFailed(detailedMessage)
                state = .failed(wrappedError)
                onCompleted?(.failure(wrappedError))
            } else {
                state = .finished
                onCompleted?(.success(currentText))
            }
        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension VolcengineStreamingSTT: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            self?.handleConnected()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            self?.handleDisconnected(error: nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.logger.error("URLSession task completed with error: \(error.localizedDescription) code=\((error as NSError).code) domain=\((error as NSError).domain)")
            }
            self.handleDisconnected(error: error)
        }
    }
}

// MARK: - Error

enum VolcengineSTTError: LocalizedError {
    case serverError(code: Int, message: String)
    case connectionFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .serverError(let code, let message):
            return "Volcengine ASR error (\(code)): \(message)"
        case .connectionFailed(let reason):
            return "Volcengine ASR connection failed: \(reason)"
        case .notConfigured:
            return "Volcengine ASR is not configured. Add your API key in Settings."
        }
    }
}
