import CryptoKit
import JavaScriptCore
import Observation
import SwiftUI
import UIKit

enum HTMLReport {
    static let inlineByteLimit = 5 * 1024 * 1024

    static func rendersInline(_ reference: TranscriptMediaReference, loader: TranscriptHTMLReportLoader?,
                              isStreaming: Bool) -> Bool {
        reference.isHTMLReportCandidate && loader != nil && !isStreaming
    }
}

enum DrawableFence {
    case svg
    case mermaid
    case html

    init?(language: String?, isStreaming: Bool) {
        guard !isStreaming else { return nil }
        switch MarkdownHighlightPolicy.normalizedLanguage(from: language) {
        case "svg": self = .svg
        case "mermaid": self = .mermaid
        case "html": self = .html
        default: return nil
        }
    }

    func page(for source: String, width: CGFloat) -> String? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .svg:
            guard XMLRootElementReader.rootName(of: source) == "svg" else { return nil }
            return Self.card(source)
        case .mermaid:
            return MermaidDiagram.svg(for: source, maxWidth: width - Self.cardInsets).map(Self.card)
        case .html:
            return source.isEmpty ? nil : source
        }
    }

    private static let cardInsets: CGFloat = 56

    private static func card(_ svg: String) -> String {
        """
        <!doctype html><html><head><style>
        body{margin:0;padding:16px}
        .svg-card{background:#fff;color:#000;border-radius:14px;padding:12px;overflow-x:auto}
        .svg-card>svg{display:block;margin:0 auto}
        .svg-card>svg[viewBox]:not(.pele){width:100%;height:auto}
        </style></head><body><div class="svg-card">\(svg)</div></body></html>
        """
    }
}

enum MermaidDiagram {
    static func svg(for source: String, maxWidth: CGFloat) -> String? {
        guard let url = Bundle.main.url(forResource: "pele.global", withExtension: "js"),
              let engine = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(engine, withSourceURL: url)
        let options: [String: Any] = ["links": false, "images": false, "maxWidth": Double(maxWidth)]
        let result = context.objectForKeyedSubscript("pele")?
            .invokeMethod("render", withArguments: [source, options])
        guard context.exception == nil, let svg = result?.objectForKeyedSubscript("svg"), svg.isString else {
            return nil
        }
        return svg.toString()
    }
}

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
            "--muted:\(css(palette.fill))",
            "--muted-foreground:\(css(palette.textSecondary))",
            "--border:\(css(palette.separator))",
            "--primary:\(css(palette.accent))",
            "--primary-foreground:\(css(palette.onAccent))",
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
    var cssValue: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(red)) \(channel(green)) \(channel(blue)) / \(String(format: "%.2f", Double(alpha))))"
    }
}

enum HTMLReportNavigation {
    enum Decision: Equatable {
        case allow
        case cancel
        case open(URL)
        case anchor(String)
    }

    static func decision(for url: URL?, isMainFrame: Bool, isLinkTap: Bool, hasLoaded: Bool) -> Decision {
        guard isMainFrame else { return .allow }
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about" {
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

struct HTMLReportMeasurement: Equatable {
    let height: CGFloat
    let isClipped: Bool
}

@MainActor enum HTMLReportCache {
    private static var measurements: [String: HTMLReportMeasurement] = [:]

    static func key(namespace: String, reference: TranscriptMediaReference, width: CGFloat,
                    family: AppFontFamily, dynamicTypeSize: DynamicTypeSize) -> String {
        "\(namespace)|\(reference.id)|\(Int(width.rounded()))|\(family.rawValue)|\(dynamicTypeSize)"
    }

    static func measurement(for key: String) -> HTMLReportMeasurement? { measurements[key] }
    static func store(_ measurement: HTMLReportMeasurement, for key: String) { measurements[key] = measurement }

}

@MainActor @Observable final class HTMLReportSnapshots {
    static let shared = HTMLReportSnapshots()

    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var bytes = 0
    @ObservationIgnored private let byteLimit: Int

    init(byteLimit: Int = 48 * 1024 * 1024) { self.byteLimit = byteLimit }

    func image(for key: String) -> UIImage? { images[key] }

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

@Observable final class TranscriptHTMLReportLoader: Equatable {
    @ObservationIgnored var load: (TranscriptMediaReference) async throws -> Data = { _ in
        throw BotArtifactFailure.unavailable
    }
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
    func transcriptHTMLReports(loadKey: Int?, load: ((TranscriptMediaReference) async throws -> Data)?) -> some View {
        modifier(TranscriptHTMLReportsModifier(loadKey: loadKey, load: load))
    }
}

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

@MainActor @Observable final class TranscriptHTMLReportModel {
    enum Phase: Equatable {
        case waiting
        case loading
        case ready
        case oversized
        case failed
    }

    private(set) var phase = Phase.waiting
    private(set) var data: Data?
    private(set) var html: String?
    private(set) var contentTag: String?
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
            guard !Task.isCancelled else { return }
            phase = .waiting
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    func renderFailed() { phase = .failed }

    func retry() {
        phase = .waiting
        data = nil
        html = nil
        contentTag = nil
        attempt += 1
    }
}
