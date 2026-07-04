import Foundation
import LDSwiftEventSource
import OSLog

@MainActor
protocol SSEStreamingClient: AnyObject {
    var lastEventID: String? { get }

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void)
    func stop()
}

@MainActor
final class SSEClient: SSEStreamingClient {
    private let baseConfiguration: URLSessionConfiguration
    private var eventSource: EventSource?
    private(set) var lastEventID: String?
    /// Read at stream start so a new stream picks up the latest headers (#255).
    private let customHeaderProvider: @MainActor () -> [CustomHeader]

    init(
        urlSessionConfiguration: URLSessionConfiguration = .default,
        customHeaderProvider: @escaping @MainActor () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        baseConfiguration = urlSessionConfiguration
        self.customHeaderProvider = customHeaderProvider
    }

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        stop()
        lastEventID = nil

        let handler = SSEEventHandler(
            onEventID: { [weak self] eventID in
                self?.lastEventID = eventID
            },
            onEvent: onEvent
        )
        var config = EventSource.Config(handler: handler, url: url)
        config.connectionErrorHandler = { _ in .shutdown }
        // Custom headers merged underneath the built-ins so the built-ins win on
        // collision; an empty list leaves the built-in three unchanged (#255).
        config.headers = customHeaderProvider().merged(under: [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache, no-transform",
            "Accept-Encoding": "identity"
        ])

        let configuration = baseConfiguration.copy() as? URLSessionConfiguration ?? .default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlSessionConfiguration = configuration

        let source = EventSource(config: config)
        eventSource = source
        source.start()
    }

    func stop() {
        eventSource?.stop()
        eventSource = nil
    }
}

enum SSEEvent: Equatable {
    case token(String)
    case interimAssistant(InterimAssistantStreamEvent)
    case reasoning(String)
    case toolStarted(ToolStreamEvent)
    case toolCompleted(ToolStreamEvent)
    case title(TitleStreamEvent)
    case done(DoneStreamEvent)
    case approvalPending(ApprovalPendingResponse)
    case clarificationPending(ClarificationPendingResponse)
    case pendingSteerLeftover(String)
    case streamEnd
    case cancelled
    case error(String)
    case transportError(String)
    case ignored
}

struct TitleStreamEvent: Decodable, Equatable {
    let sessionId: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
    }
}

struct ToolStreamEvent: Decodable, Equatable {
    let eventType: String?
    let name: String?
    let preview: String?
    let args: [String: JSONValue]?
    let duration: Double?
    let isError: Bool?
    let stableID: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case name
        case preview
        case args
        case duration
        case isError = "is_error"
        case tid
        case id
        case toolCallID = "tool_call_id"
        case toolUseID = "tool_use_id"
        case callID = "call_id"
    }

    init(
        eventType: String?,
        name: String?,
        preview: String?,
        args: [String: JSONValue]?,
        duration: Double?,
        isError: Bool?,
        stableID: String? = nil
    ) {
        self.eventType = eventType
        self.name = name
        self.preview = preview
        self.args = args
        self.duration = duration
        self.isError = isError
        self.stableID = stableID?.nonEmptyToolStreamID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = container.decodeLossyStringIfPresent(forKey: .eventType)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        preview = container.decodeLossyStringIfPresent(forKey: .preview)
        args = try? container.decodeIfPresent([String: JSONValue].self, forKey: .args)
        duration = container.decodeLossyDoubleIfPresent(forKey: .duration)
        isError = container.decodeLossyBoolIfPresent(forKey: .isError)
        stableID = [
            container.decodeLossyStringIfPresent(forKey: .tid),
            container.decodeLossyStringIfPresent(forKey: .id),
            container.decodeLossyStringIfPresent(forKey: .toolCallID),
            container.decodeLossyStringIfPresent(forKey: .toolUseID),
            container.decodeLossyStringIfPresent(forKey: .callID)
        ].compactMap { $0?.nonEmptyToolStreamID }.first
    }
}

struct InterimAssistantStreamEvent: Decodable, Equatable {
    let text: String?
    let alreadyStreamed: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case alreadyStreamed = "already_streamed"
    }

    init(text: String? = nil, alreadyStreamed: Bool? = nil) {
        self.text = text
        self.alreadyStreamed = alreadyStreamed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        alreadyStreamed = container.decodeLossyBoolIfPresent(forKey: .alreadyStreamed)
    }
}

struct SSEEventDecoder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "SSEEventDecoder"
    )

    static func decode(eventType: String, data: String) -> SSEEvent {
        let eventData = Data(data.utf8)
        let decoder = JSONDecoder()

        switch eventType {
        case "token":
            let payload = decodePayload(TokenPayload.self, eventType: eventType, from: eventData, decoder: decoder)
            return .token(payload?.text ?? "")
        case "interim_assistant":
            let payload = decodePayload(
                InterimAssistantStreamEvent.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .interimAssistant(payload ?? InterimAssistantStreamEvent())
        case "reasoning":
            let payload = decodePayload(ReasoningPayload.self, eventType: eventType, from: eventData, decoder: decoder)
            return .reasoning(payload?.text ?? "")
        case "tool":
            let payload = decodePayload(ToolStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .toolStarted(payload ?? ToolStreamEvent())
        case "tool_complete":
            let payload = decodePayload(ToolStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .toolCompleted(payload ?? ToolStreamEvent())
        case "title":
            let payload = decodePayload(TitleStreamEvent.self, eventType: eventType, from: eventData, decoder: decoder)
            return .title(payload ?? TitleStreamEvent())
        case "done":
            guard let payload = decodePayload(DonePayload.self, eventType: eventType, from: eventData, decoder: decoder) else {
                return .transportError("The stream returned a malformed completion event.")
            }
            return .done(payload.event)
        case "initial":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "pending stream payload", data: eventData)
            if ClarificationPendingResponse.containsClarificationMarkers(in: eventData) {
                return .clarificationPending(ClarificationPendingResponse.streamPayload(from: eventData, decoder: decoder))
            }
            return .approvalPending(ApprovalPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "approval":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "approval stream payload", data: eventData)
            return .approvalPending(ApprovalPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "clarify":
            logInvalidJSONIfNeeded(eventType: eventType, payloadName: "clarification stream payload", data: eventData)
            return .clarificationPending(ClarificationPendingResponse.streamPayload(from: eventData, decoder: decoder))
        case "pending_steer_leftover":
            let payload = decodePayload(
                PendingSteerLeftoverPayload.self,
                eventType: eventType,
                from: eventData,
                decoder: decoder
            )
            return .pendingSteerLeftover(payload?.text ?? "")
        case "stream_end":
            return .streamEnd
        case "cancel":
            return .cancelled
        case "error", "apperror":
            // "apperror" is one of the four socket-closing frames (stream_end, cancel,
            // error, apperror). The docs describe its payload as {error, type, session,
            // terminal_state?} while the pinned upstream emits {message, type, hint,
            // details, …}; decoding both `error` and `message` covers either shape.
            // Mapping it onto `.error` reuses the existing terminal error path
            // (surface the message, finish the stream) unchanged.
            guard let payload = decodePayload(ErrorPayload.self, eventType: eventType, from: eventData, decoder: decoder) else {
                return .error(String(localized: "The stream returned a malformed error event."))
            }
            return .error(payload.error ?? payload.message ?? String(localized: "The stream returned an error."))
        default:
            logger.debug("Ignoring unknown SSE event type '\(eventType, privacy: .public)'.")
            return .ignored
        }
    }

    private static func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        eventType: String,
        from data: Data,
        decoder: JSONDecoder
    ) -> Payload? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logDecodeFailure(eventType: eventType, payloadName: String(describing: type), error: error, data: data)
            return nil
        }
    }

    private static func logInvalidJSONIfNeeded(eventType: String, payloadName: String, data: Data) {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            logDecodeFailure(eventType: eventType, payloadName: payloadName, error: error, data: data)
        }
    }

    private static func logDecodeFailure(eventType: String, payloadName: String, error: Error, data: Data) {
        logger.debug(
            """
            Failed to decode SSE event '\(eventType, privacy: .public)' as \(payloadName, privacy: .public) \
            (\(data.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)
            """
        )
    }
}

private extension TitleStreamEvent {
    init() {
        sessionId = nil
        title = nil
    }
}

private extension ToolStreamEvent {
    init() {
        eventType = nil
        name = nil
        preview = nil
        args = nil
        duration = nil
        isError = nil
        stableID = nil
    }
}

private extension String {
    var nonEmptyToolStreamID: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class SSEEventHandler: EventHandler {
    private let onEventID: @MainActor (String) -> Void
    private let onEvent: @MainActor (SSEEvent) -> Void

    init(
        onEventID: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (SSEEvent) -> Void
    ) {
        self.onEventID = onEventID
        self.onEvent = onEvent
    }

    func onOpened() {}

    func onClosed() {}

    func onMessage(eventType: String, messageEvent: MessageEvent) {
        let event = SSEEventDecoder.decode(eventType: eventType, data: messageEvent.data)

        Task { @MainActor in
            let eventID = messageEvent.lastEventId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !eventID.isEmpty {
                onEventID(eventID)
            }
            onEvent(event)
        }
    }

    func onComment(comment: String) {}

    func onError(error: Error) {
        Task { @MainActor in
            onEvent(.transportError(error.localizedDescription))
        }
    }
}

private struct TokenPayload: Decodable {
    let text: String?
}

private struct ReasoningPayload: Decodable {
    let text: String?
}

private struct ErrorPayload: Decodable {
    let error: String?
    let message: String?
}

struct DoneStreamEvent: Equatable {
    let usage: ContextWindowSnapshot?
    let session: SessionDetail?

    init(usage: ContextWindowSnapshot? = nil, session: SessionDetail? = nil) {
        self.usage = usage
        self.session = session
    }
}

private struct DonePayload: Decodable {
    let event: DoneStreamEvent

    enum CodingKeys: String, CodingKey {
        case usage
        case session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = DoneStreamEvent(
            usage: try Self.decodeUsage(from: container),
            session: try Self.decodeSession(from: container)
        )
    }

    private static func decodeUsage(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ContextWindowSnapshot? {
        guard container.contains(.usage) else {
            return nil
        }

        return try container.decodeIfPresent(ContextWindowSnapshot.self, forKey: .usage)
    }

    private static func decodeSession(from container: KeyedDecodingContainer<CodingKeys>) throws -> SessionDetail? {
        guard container.contains(.session),
              let value = try container.decodeIfPresent(JSONValue.self, forKey: .session)
        else {
            return nil
        }

        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: data)
    }
}

private struct PendingSteerLeftoverPayload: Decodable {
    let text: String?
}
