import SwiftUI
import UIKit
import WebKit

/// Lets an inline report row take a still image of its page before the page is released.
@MainActor final class HTMLReportWebViewHandle {
    fileprivate weak var webView: WKWebView?

    /// At most 2x, so a page three screens tall stays a bounded image; it shows only until the
    /// live page paints again.
    func snapshot() async -> UIImage? {
        guard let webView, webView.bounds.width > 0, webView.bounds.height > 0,
              let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        guard image.scale > 2 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

/// One agent-generated HTML page (#1623), shared by the inline transcript row and the sheet.
///
/// The page runs JavaScript and loads remote resources, as a browser would, but reaches nothing
/// of Hermex's: it loads from a string with an opaque origin into a non-persistent data store,
/// so no cookie, credential or custom header of any server is in reach. Camera, microphone,
/// motion, downloads and new windows are refused, and its top frame can't navigate
/// (`HTMLReportNavigation`); tapped links go to the environment's `openURL`. The app's scripts
/// run in their own content world, so the page can't call them or message the app at all.
///
/// The view stays transparent until the page has painted, so a dark page never flashes white.
/// When the web process dies it reloads once, then reports `onFailure`.
struct HTMLReportWebView: UIViewRepresentable {
    let html: String
    let theme: HTMLReportTheme
    /// Inline rows don't scroll: they measure the page once and show it at that height. The
    /// sheet scrolls.
    let scrolls: Bool
    var handle: HTMLReportWebViewHandle?
    /// The page's content height once it has loaded and painted; the inline row locks its
    /// height to it. Without it, the page shows as soon as it finishes loading.
    var onMeasure: ((CGFloat) -> Void)?
    var onFailure: (() -> Void)?
    /// A tapped link to an anchor in the page. An inline row can't scroll to it, so it opens the
    /// sheet instead; without this, the page jumps to the anchor itself.
    var onAnchorTap: (() -> Void)?
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = scrolls
        webView.scrollView.contentInsetAdjustmentBehavior = scrolls ? .automatic : .never
        webView.alpha = 0
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        handle?.webView = webView
        context.coordinator.webView = webView
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        handle?.webView = webView
        context.coordinator.apply(theme)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.webView = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HTMLReportWebView
        weak var webView: WKWebView?
        private var appliedTheme: HTMLReportTheme?
        private var hasLoaded = false
        private var didReload = false
        private var measureTask: Task<Void, Never>?

        init(_ parent: HTMLReportWebView) { self.parent = parent }

        deinit { measureTask?.cancel() }

        /// Loads the page with the current theme already in place, so its first paint is themed.
        func load() {
            guard let webView else { return }
            hasLoaded = false
            appliedTheme = parent.theme
            let scripts = webView.configuration.userContentController
            scripts.removeAllUserScripts()
            scripts.addUserScript(WKUserScript(
                source: Self.bootstrap(css: parent.theme.css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            webView.loadHTMLString(parent.html, baseURL: nil)
        }

        /// Restyles a live page in place. A later reload starts from the new theme too.
        func apply(_ theme: HTMLReportTheme) {
            guard let webView, theme != appliedTheme else { return }
            appliedTheme = theme
            let scripts = webView.configuration.userContentController
            scripts.removeAllUserScripts()
            scripts.addUserScript(WKUserScript(
                source: Self.bootstrap(css: theme.css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            webView.callAsyncJavaScript(
                "const s = document.getElementById('hermex-theme'); if (s) { s.textContent = css; }",
                arguments: ["css": theme.css],
                in: nil,
                in: .defaultClient,
                completionHandler: nil
            )
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
            switch HTMLReportNavigation.decision(
                for: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                isLinkTap: navigationAction.navigationType == .linkActivated,
                hasLoaded: hasLoaded
            ) {
            case .allow:
                decisionHandler(.allow)
            case let .anchor(anchor):
                decisionHandler(.cancel)
                if let onAnchorTap = parent.onAnchorTap {
                    onAnchorTap()
                } else {
                    webView.callAsyncJavaScript(
                        "(document.getElementById(anchor) || document.getElementsByName(anchor)[0])?.scrollIntoView()",
                        arguments: ["anchor": anchor],
                        in: nil,
                        in: .defaultClient,
                        completionHandler: nil
                    )
                }
            case .cancel:
                decisionHandler(.cancel)
            case let .open(url):
                decisionHandler(.cancel)
                parent.openURL(url)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoaded = true
            guard let onMeasure = parent.onMeasure else {
                webView.alpha = 1
                return
            }
            measureTask?.cancel()
            measureTask = Task { [weak self, weak webView] in
                let height = try? await webView?.callAsyncJavaScript(
                    Self.measureScript, contentWorld: .defaultClient
                ) as? Double
                guard !Task.isCancelled, let self, let webView, self.webView === webView else { return }
                webView.alpha = 1
                onMeasure(CGFloat(height ?? 0))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failIfUnloaded(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failIfUnloaded(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if didReload {
                parent.onFailure?()
                return
            }
            didReload = true
            webView.alpha = 0
            load()
        }

        /// A cancelled navigation (a refused link, an anchor) is not a failed page.
        private func failIfUnloaded(_ error: Error) {
            guard !hasLoaded, (error as? URLError)?.code != .cancelled,
                  (error as NSError).code != 102 /* WebKitErrorFrameLoadInterruptedByPolicyChange */ else { return }
            parent.onFailure?()
        }

        // MARK: UI

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if case let .open(url) = HTMLReportNavigation.decision(
                for: navigationAction.request.url, isMainFrame: true,
                isLinkTap: navigationAction.navigationType == .linkActivated, hasLoaded: true
            ) {
                parent.openURL(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        // MARK: Scripts

        /// Runs before the page's own content: the theme as the first style in the document, so
        /// every later rule of the page's wins, and a phone-width viewport for a page that names
        /// none. A page's own viewport comes later and wins too.
        private static func bootstrap(css: String) -> String {
            let literal = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            return """
            (() => {
              const root = document.documentElement;
              if (!root) return;
              const style = document.createElement('style');
              style.id = 'hermex-theme';
              style.textContent = \(literal);
              root.insertBefore(style, root.firstChild);
              const viewport = document.createElement('meta');
              viewport.name = 'viewport';
              viewport.content = 'width=device-width, initial-scale=1';
              root.insertBefore(viewport, root.firstChild);
            })();
            """
        }

        /// The page's content height after two frames, so script-drawn content has laid out.
        /// `scrollHeight` never reports less than the view, so a page shorter than the view
        /// measures its elements instead.
        private static let measureScript = """
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const root = document.documentElement;
        const body = document.body;
        if (root.scrollHeight > window.innerHeight) return root.scrollHeight;
        const bodyBottom = body ? body.getBoundingClientRect().bottom + window.scrollY : 0;
        return Math.ceil(Math.max(root.getBoundingClientRect().height, bodyBottom));
        """
    }
}

/// A report in its full-height sheet: it scrolls, follows the app's theme, and routes its links
/// as the transcript does.
struct HTMLReportSheetPage: View {
    let html: String
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var didFail = false

    var body: some View {
        if didFail {
            ContentUnavailableView("Couldn't Display This Report", systemImage: "exclamationmark.triangle")
        } else {
            HTMLReportWebView(
                html: html,
                theme: HTMLReportTheme(appearance: appearance, colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize),
                scrolls: true,
                onFailure: { didFail = true }
            )
            .ignoresSafeArea(edges: .bottom)
            .transcriptLinks()
        }
    }
}
