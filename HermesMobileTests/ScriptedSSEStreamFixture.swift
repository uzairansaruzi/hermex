import Foundation
import Observation
@testable import HermesMobile

/// A scripted, multi-connection mock of `SSEStreamingClient` for driving full
/// disconnect → reconnect → replay sequences through `ChatStreamCoordinator`.
///
/// Each element of `connectionScripts` describes one SSE connection: the wire
/// events that connection delivers, in order. Every `start(url:onEvent:)` call
/// arms the next script; the test then plays it explicitly with
/// `playArmedConnectionScript()`. Explicit play keeps delivery deterministic
/// (no timers) and avoids re-entering the coordinator while its own `start`
/// call is still on the stack.
///
/// Fidelity rules mirror the real `SSEClient`:
/// - `lastEventID` persists across events and only updates when an event
///   carries a non-nil ID (the real client ignores empty `Last-Event-ID`s).
/// - `stop()` tears down delivery: scripted events played after `stop()` are
///   dropped, not delivered, and counted in `droppedEventCount` so a
///   mis-scripted test cannot pass silently.
///
/// Observable, so a test can wait for a reconnect's `start` instead of polling.
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

    /// Synchronous content-flush hook, same de-flake seam the spy client in
    /// `ChatViewModelSendTests` uses (PR #217): after each delivered event the
    /// view model's pending streaming content is flushed immediately, so
    /// transcript assertions never race the real ~16ms coalescing window.
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

    /// Delivers the script armed by the most recent `start(url:onEvent:)`.
    /// Safe to call when nothing is armed (delivers nothing) so tests can
    /// assert no extra connection script ran.
    func playArmedConnectionScript() {
        guard let script = armedScript else { return }

        armedScript = nil
        for step in script {
            deliver(step)
        }
    }

    /// Ad-hoc single-event delivery for sequences a test builds up
    /// imperatively on the current connection.
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
