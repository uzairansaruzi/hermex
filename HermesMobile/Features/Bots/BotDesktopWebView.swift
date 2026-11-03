import SwiftUI
import WebKit

/// URLSession owns the socket so Connection Headers
/// work through tunnels and credentials/tickets never enter the WebKit process.
@MainActor struct BotDesktopWebView: UIViewRepresentable {
    let desktop: BotDesktopSession
    let controlEnabled: Bool
    let trackpad: Bool

    func makeCoordinator() -> Coordinator { Coordinator(desktop: desktop) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "desktop")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        desktop.sendInput = { [weak coordinator = context.coordinator] command, arguments in
            coordinator?.input(command, arguments: arguments)
        }
        context.coordinator.waitForReady()
        if let directory = Bundle.main.url(forResource: "BotDesktop", withExtension: "bundle") {
            let page = directory.appendingPathComponent("viewer.html")
            context.coordinator.page = page
            view.loadFileURL(page, allowingReadAccessTo: directory)
        } else { context.coordinator.unavailable = true }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.controlEnabled = controlEnabled
        context.coordinator.trackpad = trackpad
        context.coordinator.update()
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.dispose()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "desktop")
        view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var page: URL?
        var unavailable = false
        private let desktop: BotDesktopSession
        private var ready = false
        private var modelGeneration: Int?
        private var epoch = 0
        private var socket: URLSessionWebSocketTask?
        private var reader: Task<Void, Never>?
        private var writer: Task<Void, Never>?
        private var handshake: Task<Void, Never>?
        private let socketDelegate = BotDesktopSocketDelegate()
        private var queuedBytes = 0
        private var readiness: Task<Void, Never>?
        var controlEnabled = false
        var trackpad = false
        private var sentControl = false
        private var sentTrackpad: Bool?

        init(desktop: BotDesktopSession) { self.desktop = desktop }

        func waitForReady() {
            readiness?.cancel()
            readiness = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, !ready else { return }
                unavailable = true
                update()
            }
        }

        func update() {
            guard desktop.request != nil else { if socket != nil { stop() }; return }
            if modelGeneration == desktop.generation { syncInput(); return }
            guard ready, !unavailable, let request = desktop.request else {
                if unavailable {
                    let generation = desktop.generation, owner = epoch
                    Task { [weak self] in
                        guard let self, epoch == owner else { return }
                        desktop.rendererFailed(generation: generation)
                    }
                }
                return
            }
            stop()
            modelGeneration = desktop.generation
            let owner = epoch
            let task = desktop.socketSession.webSocketTask(with: request)
            task.delegate = socketDelegate
            task.maximumMessageSize = 4 * 1024 * 1024
            socket = task
            // Opening noVNC precedes receiving bytes, and the receive loop awaits each
            // WebKit delivery. This bounds buffering instead of enqueueing frames forever.
            reader = Task { [weak self] in
                guard let self, let webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript("window.HermexDesktop.open(generation)", arguments: ["generation": owner], contentWorld: .page)
                    guard epoch == owner else { return }
                    task.resume()
                    while !Task.isCancelled, epoch == owner {
                        let message = try await task.receive()
                        guard epoch == owner else { return }
                        guard case .data(let bytes) = message, bytes.count <= 4 * 1024 * 1024 else {
                            ended(code: 4403, owner: owner); return
                        }
                        _ = try await webView.callAsyncJavaScript("window.HermexDesktop.receive(data, generation)",
                            arguments: ["data": bytes.base64EncodedString(), "generation": owner], contentWorld: .page)
                    }
                } catch {
                    ended(code: Int(task.closeCode.rawValue), httpStatus: (task.response as? HTTPURLResponse)?.statusCode, owner: owner)
                }
            }
            handshake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.ended(code: 0, owner: owner)
            }
        }

        func dispose() {
            readiness?.cancel(); readiness = nil
            stop()
        }

        func stop() {
            epoch += 1
            reader?.cancel(); reader = nil
            writer?.cancel(); writer = nil
            handshake?.cancel(); handshake = nil
            // A reconnect/background suspension must not read as a deliberate hand-back.
            socket?.cancel(); socket = nil
            modelGeneration = nil
            queuedBytes = 0
            sentControl = false
            sentTrackpad = nil
            webView?.evaluateJavaScript("window.HermexDesktop && window.HermexDesktop.disconnect()", completionHandler: nil)
        }

        func input(_ command: String, arguments: [String: Any]) {
            guard controlEnabled, sentControl, modelGeneration == desktop.generation else { return }
            sendInput(command, arguments: arguments)
        }

        private func sendInput(_ command: String, arguments: [String: Any]) {
            webView?.callAsyncJavaScript("window.HermexDesktop.input(command, args, generation)",
                arguments: ["command": command, "args": arguments, "generation": epoch], in: nil, in: .page,
                completionHandler: nil)
        }

        private func syncInput() {
            // SwiftUI passes the lease as a value so changing it updates an existing WKWebView.
            let controls = controlEnabled && desktop.phase == .live && desktop.controlsDesktop
            if controls != sentControl {
                sentControl = controls
                sendInput("control", arguments: ["enabled": controls])
                sentTrackpad = nil
            }
            if controls && trackpad != sentTrackpad {
                sentTrackpad = trackpad
                sendInput("trackpad", arguments: ["enabled": trackpad])
            }
        }

        private func ended(code: Int, httpStatus: Int? = nil, owner: Int) {
            guard epoch == owner, let generation = modelGeneration else { return }
            stop()
            desktop.disconnected(code: code, httpStatus: httpStatus, generation: generation)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "ready" { readiness?.cancel(); readiness = nil; ready = true; update(); return }
            guard let socket, let generation = modelGeneration,
                  let eventGeneration = body["generation"] as? Int, eventGeneration == epoch else { return }
            let owner = epoch
            switch type {
            case "frame":
                handshake?.cancel(); handshake = nil
                desktop.connected(generation: generation)
                syncInput()
            case "clipboard":
                if controlEnabled, let text = body["text"] as? String { desktop.receiveClipboard(text, generation: generation) }
            case "failed", "close": ended(code: 0, owner: owner)
            case "send":
                guard let encoded = body["data"] as? String, encoded.utf8.count <= 90_000,
                      let data = Data(base64Encoded: encoded), data.count <= 65_536,
                      queuedBytes + data.count <= 262_144 else { ended(code: 4403, owner: owner); return }
                queuedBytes += data.count
                let previous = writer
                writer = Task { [weak self] in
                    await previous?.value
                    guard let self, epoch == owner, !Task.isCancelled else { return }
                    do { try await socket.send(.data(data)) }
                    catch { ended(code: 0, owner: owner) }
                    if epoch == owner { queuedBytes -= data.count }
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            unavailable = true; update()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            unavailable = true; update()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; unavailable = false
            waitForReady()
            if let generation = modelGeneration { stop(); desktop.disconnected(code: 0, generation: generation) }
            if let page { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        }
    }
}

/// A display ticket and proxy headers must never follow even a same-host redirect.
/// The observed endpoint is exact; a redirect is a connection failure, not discovery.
private final class BotDesktopSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
