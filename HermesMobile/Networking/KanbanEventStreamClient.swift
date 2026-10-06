import Foundation
import LDSwiftEventSource

enum KanbanStreamFrame: Equatable, Sendable {
    /// webui's handshake: the stream is live at `cursor` for `board`.
    case hello(cursor: Int, board: String)
    /// A Hermes socket's upgrade succeeded. The host sends no hello, so this stands in for it.
    case opened
    case events(events: [KanbanEvent], cursor: Int, frameID: Int?)
    case ignored
    case malformed
}

enum KanbanStreamFrameDecoder {
    static func decode(eventType: String, data: String, frameID: String?) -> KanbanStreamFrame {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        switch eventType {
        case "hello":
            guard let payload = try? decoder.decode(Hello.self, from: Data(data.utf8)),
                  let cursor = payload.cursor,
                  cursor >= 0,
                  let board = normalized(payload.board) else {
                return .malformed
            }
            return .hello(cursor: cursor, board: board)
        case "events":
            guard let payload = try? decoder.decode(Events.self, from: Data(data.utf8)),
                  let events = payload.events,
                  let cursor = payload.cursor,
                  cursor >= 0 else {
                return .malformed
            }
            let parsedFrameID = frameID.flatMap(Int.init)
            guard frameID == nil || parsedFrameID != nil else { return .malformed }
            return .events(events: events, cursor: cursor, frameID: parsedFrameID)
        default:
            return .ignored
        }
    }

    /// One frame from a Hermes host's Kanban socket (#1045): `{events, cursor}`, read as webui's
    /// `events` frame without a frame id. A JSON object with neither key is some other message
    /// a newer host might add, and is ignored rather than ending the socket.
    static func decodeSocketFrame(_ data: Data) -> KanbanStreamFrame {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Events.self, from: data) else { return .malformed }
        guard payload.events != nil || payload.cursor != nil else { return .ignored }
        guard let events = payload.events, let cursor = payload.cursor, cursor >= 0 else { return .malformed }
        return .events(events: events, cursor: cursor, frameID: nil)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct Hello: Decodable {
        let cursor: Int?
        let board: String?
    }

    private struct Events: Decodable {
        let events: [KanbanEvent]?
        let cursor: Int?
    }
}

/// One Board's live events. `KanbanFeatureState` starts it at the Board's cursor while the
/// Board is on screen and the app is active, and stops it otherwise. A client reports each
/// frame and at most one failure per `start`, and nothing after `stop()`.
@MainActor
protocol KanbanEventStreamingClient: AnyObject {
    func start(
        board: String,
        since: Int,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    )
    func stop()
}

/// webui's SSE stream, `/api/kanban/events/stream` on `server`, with the custom headers.
@MainActor
final class KanbanEventStreamClient: KanbanEventStreamingClient {
    private let server: URL
    private let baseConfiguration: URLSessionConfiguration
    private let customHeaderProvider: @MainActor () -> [CustomHeader]
    private var eventSource: EventSource?

    init(
        server: URL,
        urlSessionConfiguration: URLSessionConfiguration = .default,
        customHeaderProvider: @escaping @MainActor () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        self.server = server
        baseConfiguration = urlSessionConfiguration
        self.customHeaderProvider = customHeaderProvider
    }

    func start(
        board: String,
        since: Int,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        stop()
        let url = Endpoint.kanbanEventsStream(KanbanEventsStreamRequest(board: board, since: since))
            .url(relativeTo: server)
        let handler = Handler(onFrame: onFrame, onFailure: onFailure)
        var config = EventSource.Config(handler: handler, url: url)
        config.connectionErrorHandler = { _ in .shutdown }
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

    private final class Handler: EventHandler {
        private let onFrame: @MainActor (KanbanStreamFrame) -> Void
        private let onFailure: @MainActor () -> Void

        init(
            onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
            onFailure: @escaping @MainActor () -> Void
        ) {
            self.onFrame = onFrame
            self.onFailure = onFailure
        }

        func onOpened() {}
        func onClosed() {
            Task { @MainActor in onFailure() }
        }
        func onComment(comment: String) {}

        func onMessage(eventType: String, messageEvent: MessageEvent) {
            let frame = KanbanStreamFrameDecoder.decode(
                eventType: eventType,
                data: messageEvent.data,
                frameID: messageEvent.lastEventId.nilIfEmpty
            )
            Task { @MainActor in onFrame(frame) }
        }

        func onError(error: Error) {
            // Never include the transport error or event payload in logs.
            Task { @MainActor in onFailure() }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
