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

    // MARK: - Public API

    func start(configuration: Configuration) {
        guard case .idle = state else {
            logger.warning("start() called in non-idle state")
            return
        }

        self.configuration = configuration
        self.currentText = ""
        self.hasReceivedResult = false
        state = .connecting

        let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        var request = URLRequest(url: endpoint)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        logger.info("WebSocket connecting to Volcengine ASR, connectId=\(self.connectId)")
    }

    /// Send a PCM audio frame (16kHz, mono, 16-bit, ~200ms recommended).
    func sendAudioFrame(_ pcmData: Data) {
        guard case .streaming = state else { return }
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

    private func parseServerResponse(_ data: Data) {
        guard data.count >= 4 else {
            logger.warning("Response too short: \(data.count) bytes")
            return
        }

        let byte1 = data[1]
        let msgType = (byte1 >> 4) & 0x0F

        if msgType == 0x0F {
            // Error message from server
            parseErrorResponse(data)
            return
        }

        guard msgType == 0x09 else {
            logger.debug("Ignoring message type: 0x\(String(format: "%02X", msgType))")
            return
        }

        // Full server response — extract JSON payload
        guard data.count >= 8 else { return }
        let payloadSize = data.subdata(in: 4..<8).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        guard data.count >= 8 + Int(payloadSize) else {
            logger.warning("Incomplete payload: expected \(payloadSize), got \(data.count - 8)")
            return
        }

        let payloadData = data.subdata(in: 8..<(8 + Int(payloadSize)))

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

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let result = json["result"] as? [String: Any],
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
        guard case .streaming = state else { return }
        if let error {
            state = .failed(error)
            onCompleted?(.failure(error))
        } else {
            state = .finished
            onCompleted?(.success(currentText))
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
            self?.handleDisconnected(error: error)
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
