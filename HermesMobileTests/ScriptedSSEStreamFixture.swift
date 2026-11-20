import Foundation
import Observation
@testable import HermesMobile

@MainActor @Observable
final class ScriptedSSEStreamingClient: SSEStreamingClient {
    struct ScriptedEvent {
        let event: SSEEvent
        let lastEventID: String?

        init(_ event: SSEEvent, lastEventID: String? = nil) {
            self.event = event
            self.lastEventID = lastEventID
        }
    }

    private var connectionScripts: [[ScriptedEvent]]
    private var nextScriptIndex = 0
    private var armedScript: [ScriptedEvent]?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private(set) var droppedEventCount = 0

    var flushPendingStreamingContent: (() -> Void)?

    init(connectionScripts: [[ScriptedEvent]] = []) {
        self.connectionScripts = connectionScripts
    }

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
        if nextScriptIndex < connectionScripts.count {
            armedScript = connectionScripts[nextScriptIndex]
            nextScriptIndex += 1
        } else {
            armedScript = nil
        }
    }

    func stop() {
        stopCount += 1
        onEvent = nil
    }

    func playArmedConnectionScript() {
        guard let script = armedScript else { return }

        armedScript = nil
        for step in script {
            deliver(step)
        }
    }

    func emit(_ event: SSEEvent, lastEventID: String? = nil) {
        deliver(ScriptedEvent(event, lastEventID: lastEventID))
    }

    private func deliver(_ step: ScriptedEvent) {
        guard let onEvent else {
            droppedEventCount += 1
            return
        }

        if let eventID = step.lastEventID {
            lastEventID = eventID
        }
        onEvent(step.event)
        flushPendingStreamingContent?()
    }
}
