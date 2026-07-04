import SwiftUI
import WebKit

struct WikiBrowserSheet: View {
    let route: WikiRoute

    var body: some View {
        NavigationStack {
            WikiBrowserView(initialRoute: route)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct WikiNativePageSheet: View {
    let route: WikiRoute
    let onOpenWeb: (WikiRoute) -> Void
    let onOpenRoute: (WikiRoute) -> Void

    @AppStorage(WikiSettings.baseURLKey) private var wikiBaseURLString = WikiSettings.defaultBaseURLString
    @State private var loadState: WikiNativePageLoadState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(route.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Open Web") {
                            onOpenWeb(route)
                        }
                    }
                }
                .task(id: route.id) {
                    await loadNativePage()
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading wiki page…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let markdown):
            ScrollView {
                MarkdownRenderer(
                    content: markdown,
                    isStreaming: false,
                    onOpenWikiRoute: onOpenRoute
                )
                .padding(ZoraSpacing.screenInset)
                .zoraAdaptiveContentFrame(.readablePage)
            }
            .background(Color.clear)
            .scrollContentBackground(.hidden)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Render Natively", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Open Web View") {
                    onOpenWeb(route)
                }
            }
            .padding()
        }
    }

    private var wikiBaseURL: URL {
        WikiSettings.baseURL(from: wikiBaseURLString)
    }

    private func loadNativePage() async {
        guard case .page(let path, _) = route.kind else {
            loadState = .failed(String(localized: "Only wiki pages can be rendered natively."))
            return
        }

        loadState = .loading
        let urls = WikiURLBuilder.markdownCandidateURLs(for: path, baseURL: wikiBaseURL)

        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    continue
                }
                guard let raw = String(data: data, encoding: .utf8) else {
                    continue
                }
                let markdown = WikiMarkdownDocumentFormatter.displayMarkdown(from: raw, title: route.title)
                loadState = .loaded(markdown)
                return
            } catch {
                continue
            }
        }

        loadState = .failed(String(localized: "I tried the standard Markdown page locations for this wiki link, but none returned readable Markdown. The web view can still open the page with its saved login session."))
    }
}

private enum WikiNativePageLoadState: Equatable {
    case loading
    case loaded(String)
    case failed(String)
}

struct WikiBrowserView: View {
    let initialRoute: WikiRoute?

    @AppStorage(WikiSettings.baseURLKey) private var wikiBaseURLString = WikiSettings.defaultBaseURLString
    @StateObject private var model = WikiWebViewModel()
    @State private var addressText = ""

    init(initialRoute: WikiRoute? = nil) {
        self.initialRoute = initialRoute
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()
                .opacity(0.5)

            ZStack {
                WikiWebView(model: model)

                if model.isLoading {
                    ProgressView()
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.opacity)
                }
            }
        }
        .navigationTitle("Wiki")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.currentURL == nil)

                ShareLink(item: model.currentURL ?? currentHomeURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            let target = initialRoute?.webURL(baseURL: wikiBaseURL) ?? currentHomeURL
            addressText = displayAddress(for: target)
            model.load(target)
        }
        .onChange(of: model.currentURL) { _, newURL in
            guard let newURL else { return }
            addressText = displayAddress(for: newURL)
        }
    }

    private var wikiBaseURL: URL {
        WikiSettings.baseURL(from: wikiBaseURLString)
    }

    private var currentHomeURL: URL {
        wikiBaseURL
    }

    private var appsURL: URL {
        WikiRoute(kind: .app(path: "/apps")).webURL(baseURL: wikiBaseURL)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)

                Button {
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)

                TextField("Wiki URL", text: $addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(loadAddressText)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(ZoraBrand.subtleFill, in: Capsule())
            }
            .buttonStyle(.borderless)

            HStack(spacing: 8) {
                wikiShortcutButton("Wiki", url: currentHomeURL)
                wikiShortcutButton("Apps", url: appsURL)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func wikiShortcutButton(_ title: String, url: URL) -> some View {
        Button(title) {
            addressText = displayAddress(for: url)
            model.load(url)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ZoraBrand.cardFill, in: Capsule())
        .overlay(Capsule().stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
        .buttonStyle(.plain)
    }

    private func loadAddressText() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL?
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            url = absolute
        } else {
            url = WikiURLBuilder.url(forWikiPath: trimmed, baseURL: wikiBaseURL, preferredExtension: nil)
        }

        guard let url else { return }
        addressText = displayAddress(for: url)
        model.load(url)
    }

    private func displayAddress(for url: URL) -> String {
        url.absoluteString
    }
}

final class WikiWebViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    let webView: WKWebView
    private var observationTokens: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        observeWebView()
    }

    deinit {
        observationTokens.forEach { $0.invalidate() }
    }

    func load(_ url: URL) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    private func observeWebView() {
        observationTokens = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.currentURL = webView.url
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.canGoForward = webView.canGoForward
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.isLoading = webView.isLoading
                }
            }
        ]
    }
}

struct WikiWebView: UIViewRepresentable {
    @ObservedObject var model: WikiWebViewModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
