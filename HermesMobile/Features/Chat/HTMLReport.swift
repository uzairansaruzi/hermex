import CryptoKit
import Observation
import SwiftUI
import UIKit

/// An agent-generated `.html` report in a Hermes reply (#1623): rendered in place in the
/// transcript, and in a full-height sheet from its expand button. webui replies keep their
/// download card.
enum HTMLReport {
    /// The largest file a reply renders in place. A larger one stays a file card whose tap
    /// opens the sheet, which takes up to `BotArtifactBuffer.maximumBytes`.
    static let inlineByteLimit = 5 * 1024 * 1024

    /// Whether a reply's file renders in place: an HTML file in a settled reply, on a chat that
    /// publishes a loader, which only a Hermes chat does. Everything else keeps its file card.
    static func rendersInline(_ reference: TranscriptMediaReference, loader: TranscriptHTMLReportLoader?,
                              isStreaming: Bool) -> Bool {
        reference.isHTMLReportCandidate && loader != nil && !isStreaming
    }
}

/// An `svg` code fence in a reply (#1649). A settled one gains a View button in its header that
/// opens the drawing in the report sheet, in the report's sandbox. Nothing draws in the
/// transcript, and the code block stays, so the source is never lost.
enum SVGFence {
    /// Whether a fence offers View. A streaming fence doesn't: its source is still incomplete.
    static func offersView(language: String?, isStreaming: Bool) -> Bool {
        !isStreaming && MarkdownHighlightPolicy.normalizedLanguage(from: language) == "svg"
    }

    /// The sheet's page: the drawing fit to the sheet's width on a white card, since agent SVGs
    /// usually have no background and draw in black. Only an SVG with a `viewBox` can scale; one
    /// without keeps its own size and scrolls inside the card instead of being cropped. Nil when
    /// the source isn't a well-formed `<svg>` document, so the sheet shows its failure state
    /// rather than a blank page.
    static func page(for source: String) -> String? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard XMLRootElementReader.rootName(of: source) == "svg" else { return nil }
        return """
        <!doctype html><html><head><style>
        body{margin:0;padding:16px}
        .svg-card{background:#fff;color:#000;border-radius:14px;padding:12px;overflow-x:auto}
        .svg-card>svg{display:block;margin:0 auto}
        .svg-card>svg[viewBox]{width:100%;height:auto}
        </style></head><body><div class="svg-card">\(source)</div></body></html>
        """
    }
}

/// Parses a whole XML document and reports its root element's name, or nil when it isn't
/// well-formed.
private final class XMLRootElementReader: NSObject, XMLParserDelegate {
    private var rootName: String?

    static func rootName(of source: String) -> String? {
        let parser = XMLParser(data: Data(source.utf8))
        let reader = XMLRootElementReader()
        parser.delegate = reader
        return parser.parse() ? reader.rootName : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if rootName == nil { rootName = elementName }
    }
}

/// The user's theme as low-priority CSS defaults, so a page with no styles of its own looks
/// like the rest of the app. Everything sits under `:where()`, which has no specificity, so any
/// rule of the page's own wins. The variables use the common web names (`docs/agents/theming.md` § HTML reports).
struct HTMLReportTheme: Equatable {
    let css: String

    init(palette: ThemePalette, isDark: Bool, family: AppFontFamily, dynamicTypeSize: DynamicTypeSize) {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        func css(_ color: UIColor) -> String { color.resolvedColor(with: traits).cssValue }
        let bodySize = UIFont.preferredFont(forTextStyle: .body, at: dynamicTypeSize).pointSize
        let variables = [
            "--background:\(css(palette.canvas))",
            "--foreground:\(css(palette.text))",
            "--card:\(css(palette.surface))",
            "--muted-foreground:\(css(palette.textSecondary))",
            "--border:\(css(palette.separator))",
            "--primary:\(css(palette.accent))",
            "--font-sans:\(family.cssStack)",
            "--font-mono:\(Self.monoStack)"
        ].joined(separator: ";")
        self.css = """
        :where(:root){\(variables);color-scheme:\(isDark ? "dark" : "light");background:var(--background);\
        color:var(--foreground);font-family:var(--font-sans);font-size:\(Self.format(bodySize))px;\
        -webkit-text-size-adjust:100%}
        :where(body){margin:0}
        :where(a){color:var(--primary)}
        :where(code,kbd,pre,samp){font-family:var(--font-mono)}
        """
    }

    /// The theme the app shows right now. Reading the font setting makes the calling body follow it.
    init(appearance: AppAppearance, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize) {
        let isDark = colorScheme == .dark
        self.init(palette: appearance.palette(isDark: isDark), isDark: isDark,
                  family: AppFontSettings.shared.family, dynamicTypeSize: dynamicTypeSize)
    }

    private static let monoStack = #"ui-monospace,"SF Mono",Menlo,monospace"#

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

private extension AppFontFamily {
    /// The family as a CSS stack. The page's web process can't see the fonts bundled with the
    /// app, so DM Sans falls back to the system sans and Lora to Georgia.
    var cssStack: String {
        switch self {
        case .sanFrancisco, .dmSans: "-apple-system,system-ui,sans-serif"
        case .sfRounded: "ui-rounded,-apple-system,system-ui,sans-serif"
        case .avenirNext: #""Avenir Next",-apple-system,system-ui,sans-serif"#
        case .georgia, .lora: "Georgia,serif"
        case .sfMono: #"ui-monospace,"SF Mono",Menlo,monospace"#
        }
    }
}

private extension UIColor {
    /// `rgb(r g b / a)`, from a color already resolved for its traits.
    var cssValue: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(red)) \(channel(green)) \(channel(blue)) / \(String(format: "%.2f", Double(alpha))))"
    }
}

/// What a report page may do with its own top frame: nothing but load itself. A tapped web link
/// leaves through the transcript's link routing (the matching app, else the in-app browser), and
/// a tapped in-page anchor is the app's to scroll to; any other top-frame navigation, scripted or
/// not, is refused. Frames inside the page load freely.
enum HTMLReportNavigation {
    enum Decision: Equatable {
        case allow
        case cancel
        case open(URL)
        /// A tapped link to the element with this id or name.
        case anchor(String)
    }

    /// `isMainFrame` is true for a new window too, which a report never gets.
    static func decision(for url: URL?, isMainFrame: Bool, isLinkTap: Bool, hasLoaded: Bool) -> Decision {
        guard isMainFrame else { return .allow }
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about" {
            // The page loads from `about:blank`. WebKit resolves `#notes` against it as a new page,
            // `about:blank%23notes`, so an anchor can't navigate; the app scrolls to it instead.
            guard hasLoaded else { return .allow }
            guard isLinkTap, let anchor = anchor(in: url), !anchor.isEmpty else { return .cancel }
            return .anchor(anchor)
        }
        if isLinkTap, scheme == "http" || scheme == "https" { return .open(url) }
        return .cancel
    }

    private static func anchor(in url: URL) -> String? {
        if let fragment = url.fragment { return fragment.removingPercentEncoding ?? fragment }
        let encoded = url.absoluteString
        guard let marker = encoded.range(of: "%23") else { return nil }
        let raw = String(encoded[marker.upperBound...])
        return raw.removingPercentEncoding ?? raw
    }
}

/// A report row's measured height, locked after its first load.
struct HTMLReportMeasurement: Equatable {
    /// The row's height: the page's, up to the cap.
    let height: CGFloat
    /// The page is taller than the cap, so the row fades out at its bottom edge.
    let isClipped: Bool
}

/// Measured heights that outlive a chat, so reopening one keeps its reports' heights instead of
/// jumping. Keys hold the server namespace, the file, and what lays the page out (the row width,
/// the font and the text size), so nothing crosses servers and a new font or size measures again.
@MainActor enum HTMLReportCache {
    private static var measurements: [String: HTMLReportMeasurement] = [:]

    static func key(namespace: String, reference: TranscriptMediaReference, width: CGFloat,
                    family: AppFontFamily, dynamicTypeSize: DynamicTypeSize) -> String {
        "\(namespace)|\(reference.id)|\(Int(width.rounded()))|\(family.rawValue)|\(dynamicTypeSize)"
    }

    static func measurement(for key: String) -> HTMLReportMeasurement? { measurements[key] }
    static func store(_ measurement: HTMLReportMeasurement, for key: String) { measurements[key] = measurement }

}

/// The still images of off-screen reports, keyed like `HTMLReportCache`. The transcript keeps every
/// row mounted, so rows don't hold these themselves: they read them here, and dropping the oldest
/// past `byteLimit` redraws its row without the image, which frees it.
@MainActor @Observable final class HTMLReportSnapshots {
    static let shared = HTMLReportSnapshots()

    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var bytes = 0
    @ObservationIgnored private let byteLimit: Int

    init(byteLimit: Int = 48 * 1024 * 1024) { self.byteLimit = byteLimit }

    func image(for key: String) -> UIImage? { images[key] }

    /// An image larger than the whole limit, such as a tall report on an iPad, isn't kept.
    func store(_ image: UIImage, for key: String) {
        remove(key)
        guard Self.cost(of: image) <= byteLimit else { return }
        images[key] = image
        order.append(key)
        bytes += Self.cost(of: image)
        while bytes > byteLimit, order.count > 1 { remove(order[0]) }
    }

    private func remove(_ key: String) {
        guard let image = images.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        bytes -= Self.cost(of: image)
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}

/// Downloads a Hermes reply's report for its inline render, at most `HTMLReport.inlineByteLimit`
/// bytes; a larger file throws `BotArtifactFailure.tooLarge`. Only a Hermes chat publishes one
/// (`transcriptHTMLReports(loadKey:load:)`), so a webui reply keeps its download card. A reference
/// that compares by identity, so the settled reply's forwarded environment stays equal.
@Observable final class TranscriptHTMLReportLoader: Equatable {
    @ObservationIgnored var load: (TranscriptMediaReference) async throws -> Data = { _ in
        throw BotArtifactFailure.unavailable
    }
    /// The chat's current attach (`ChatViewModel.attachmentLoadKey`), nil while it is detached, as
    /// when the chat has just opened. A load that throws `BotFailure.stale` waits for this to change.
    var loadKey: Int?

    static func == (lhs: TranscriptHTMLReportLoader, rhs: TranscriptHTMLReportLoader) -> Bool { lhs === rhs }
}

private struct TranscriptHTMLReportLoaderKey: EnvironmentKey {
    static let defaultValue: TranscriptHTMLReportLoader? = nil
}

extension EnvironmentValues {
    var transcriptHTMLReportLoader: TranscriptHTMLReportLoader? {
        get { self[TranscriptHTMLReportLoaderKey.self] }
        set { self[TranscriptHTMLReportLoaderKey.self] = newValue }
    }
}

extension View {
    /// Renders the transcript's HTML reports in place, downloading each through `load` once
    /// `loadKey` names an attach. Nil leaves them as file cards.
    func transcriptHTMLReports(loadKey: Int?, load: ((TranscriptMediaReference) async throws -> Data)?) -> some View {
        modifier(TranscriptHTMLReportsModifier(loadKey: loadKey, load: load))
    }
}

/// Keeps one loader for the screen and refreshes its handler on every pass, as
/// `ChatDisclosureToggledModifier` does.
private struct TranscriptHTMLReportsModifier: ViewModifier {
    let loadKey: Int?
    let load: ((TranscriptMediaReference) async throws -> Data)?
    @State private var loader = TranscriptHTMLReportLoader()

    func body(content: Content) -> some View {
        if let load { loader.load = load }
        return content
            .environment(\.transcriptHTMLReportLoader, load == nil ? nil : loader)
            .onChange(of: loadKey, initial: true) { loader.loadKey = loadKey }
    }
}

/// One inline report's download. A failed or cancelled load leaves no state behind for a view
/// that is gone: it returns without writing.
@MainActor @Observable final class TranscriptHTMLReportModel {
    enum Phase: Equatable {
        /// Not on screen yet, so nothing has downloaded.
        case waiting
        case loading
        /// Downloaded: `data` and `html` hold the file.
        case ready
        /// Over `HTMLReport.inlineByteLimit`: the row shows a file card instead.
        case oversized
        case failed
    }

    private(set) var phase = Phase.waiting
    /// The whole file, for download, once `ready`.
    private(set) var data: Data?
    /// The page, decoded once, once `ready`.
    private(set) var html: String?
    /// A digest of `data`, which keys the locked height: an agent that rewrites a report at the
    /// same path gets the new page measured, not the old one's height.
    private(set) var contentTag: String?
    /// Bumped by `retry`, which keys the row's load task.
    private(set) var attempt = 0

    func load(_ reference: TranscriptMediaReference, using loader: TranscriptHTMLReportLoader) async {
        guard phase != .ready else { return }
        phase = .loading
        do {
            let data = try await loader.load(reference)
            guard !Task.isCancelled else { return }
            self.data = data
            html = String(decoding: data, as: UTF8.self)
            contentTag = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            phase = .ready
        } catch BotArtifactFailure.tooLarge {
            guard !Task.isCancelled else { return }
            phase = .oversized
        } catch BotFailure.stale {
            // The chat isn't attached yet, or reattached mid-download: the row loads again when
            // `TranscriptHTMLReportLoader.loadKey` changes.
            guard !Task.isCancelled else { return }
            phase = .waiting
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    /// The page's web process died twice (`HTMLReportWebView`'s one reload), or the page
    /// never loaded.
    func renderFailed() { phase = .failed }

    func retry() {
        phase = .waiting
        data = nil
        html = nil
        contentTag = nil
        attempt += 1
    }
}
