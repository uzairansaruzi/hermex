import SwiftUI
import WebKit

@MainActor struct BotDesktopView: View {
    @State private var desktop: BotDesktopSession
    @Environment(\.scenePhase) private var scenePhase
    let name: String

    init(server: URL, connection: BotConnection, profile: String, name: String) {
        _desktop = State(initialValue: BotDesktopSession(server: server, connection: connection, profile: profile))
        self.name = name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BotDesktopWebView(desktop: desktop)
                .opacity(desktop.phase == .live ? 1 : 0)
                .accessibilityLabel("View Desktop")
            if desktop.phase != .live { statePanel }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("View only").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(8).background(.regularMaterial)
        }
        .task { if scenePhase == .active { desktop.open() } }
        .onChange(of: scenePhase) {
            if scenePhase == .background { desktop.close() }
            else if scenePhase == .active { desktop.open() }
        }
        .onDisappear { desktop.close() }
    }

    @ViewBuilder private var statePanel: some View {
        switch desktop.phase {
        case .idle, .loading, .connecting:
            ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
        case .starting:
            ProgressView("Starting desktop…").tint(.white).foregroundStyle(.white)
        case .paused:
            Text("Paused").foregroundStyle(.white)
        case .live: EmptyView()
        default:
            VStack(spacing: 16) {
                Image(systemName: "desktopcomputer").font(.largeTitle)
                Text(statusText).multilineTextAlignment(.center)
                if desktop.phase == .stopped {
                    Button("Start Desktop") { desktop.start() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Try Again") { desktop.retry() }.buttonStyle(.bordered)
                }
            }
            .foregroundStyle(.white).padding(24).frame(maxWidth: 460)
        }
    }

    private var statusText: String {
        switch desktop.phase {
        case .unsupported: return String(localized: "This Hermes host does not support desktop viewing.")
        case .notInstalled: return String(localized: "Desktop software is not installed on this Hermes host.")
        case .blocked: return String(localized: "The desktop cannot start. Check its configuration on the Hermes host.")
        case .stopped: return String(localized: "The desktop is off. Starting it runs a desktop on the Hermes host.")
        default: return desktop.message
        }
    }
}

/// noVNC only sees protocol bytes. URLSession owns the socket so Connection Headers
/// work through tunnels and credentials/tickets never enter the WebKit process.
@MainActor private struct BotDesktopWebView: UIViewRepresentable {
    let desktop: BotDesktopSession

    func makeCoordinator() -> Coordinator { Coordinator(desktop: desktop) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "desktop")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        // Page zoom/pan stays local to WKWebView; noVNC never receives gestures.
        view.scrollView.isScrollEnabled = true
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.waitForReady()
        if let directory = Bundle.main.url(forResource: "BotDesktop", withExtension: "bundle") {
            let page = directory.appendingPathComponent("viewer.html")
            context.coordinator.page = page
            view.loadFileURL(page, allowingReadAccessTo: directory)
        } else { context.coordinator.unavailable = true }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update() }

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
            guard modelGeneration != desktop.generation else { return }
            guard ready, !unavailable, let request = desktop.request else {
                if unavailable {
                    let owner = desktop.generation
                    Task { desktop.disconnected(code: 4403, generation: owner) }
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
                    _ = try await webView.callAsyncJavaScript("window.HermexDesktop.open(generation)", arguments: ["generation": owner], in: nil, in: .page)
                    guard epoch == owner else { return }
                    task.resume()
                    while !Task.isCancelled, epoch == owner {
                        let message = try await task.receive()
                        guard epoch == owner else { return }
                        guard case .data(let bytes) = message, bytes.count <= 4 * 1024 * 1024 else {
                            ended(code: 4403, owner: owner); return
                        }
                        _ = try await webView.callAsyncJavaScript("window.HermexDesktop.receive(data, generation)",
                            arguments: ["data": bytes.base64EncodedString(), "generation": owner], in: nil, in: .page)
                    }
                } catch { ended(code: Int(task.closeCode.rawValue), owner: owner) }
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
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            modelGeneration = nil
            queuedBytes = 0
            webView?.evaluateJavaScript("window.HermexDesktop && window.HermexDesktop.disconnect()", completionHandler: nil)
        }

        private func ended(code: Int, owner: Int) {
            guard epoch == owner, let generation = modelGeneration else { return }
            stop()
            desktop.disconnected(code: code, generation: generation)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "ready" { readiness?.cancel(); readiness = nil; ready = true; update(); return }
            guard let socket, let generation = modelGeneration,
                  let eventGeneration = body["generation"] as? Int, eventGeneration == epoch else { return }
            let owner = epoch
            switch type {
            case "connected":
                handshake?.cancel(); handshake = nil
                desktop.connected(generation: generation)
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
