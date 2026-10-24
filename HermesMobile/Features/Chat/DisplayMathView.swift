import MarkdownUI
import SwiftMath
import SwiftUI
import UIKit

/// Renders block/display LaTeX (`$$…$$`, `\[…\]`) with the SwiftMath TeX
/// layout engine when the expression parses, and falls back to the Unicode
/// approximation (`MarkdownMathFormatter`) for anything SwiftMath can't parse.
///
/// Tolerant by design: an unparseable or partial expression degrades to the
/// previous Unicode rendering instead of crashing or showing SwiftMath's
/// inline red error. The Unicode approximation is also used as the VoiceOver
/// label on both paths, so the drawn math stays accessible.
struct DisplayMathView: View {
    let latex: String

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var mathFontSize: CGFloat = 18

    var body: some View {
        Group {
            if MathLaTeX.isRenderable(latex) {
                ScrollView(.horizontal, showsIndicators: false) {
                    SwiftMathLabelView(
                        latex: latex,
                        fontSize: mathFontSize,
                        colorScheme: colorScheme
                    )
                    .padding(.vertical, 8)
                }
            } else {
                fallback
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(approximation)
        .padding(.vertical, 2)
        // Math/LaTeX is read left-to-right regardless of the chat direction (#259);
        // mirroring it would reverse equations inside an RTL message.
        .forcedLeftToRight()
    }

    /// The pre-SwiftMath Unicode/serif rendering, kept verbatim as the graceful
    /// fallback for expressions SwiftMath cannot parse.
    private var fallback: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(approximation)
                .font(.system(.body, design: .serif))
                .lineSpacing(4)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
    }

    private var approximation: String {
        MarkdownMathFormatter.renderedText(for: latex)
    }
}

enum MathLaTeX {
    /// Renderability is a pure, deterministic function of the trimmed LaTeX
    /// string, so we memoize it. `DisplayMathView`/`MathFenceOrCodeBlock`
    /// re-check on every layout pass, and markdown-ui rebuilds code blocks on
    /// each streaming chunk — without this cache the same expression is parsed
    /// many times over. `NSCache` is thread-safe and self-evicts under memory
    /// pressure.
    nonisolated(unsafe) private static let renderableCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    /// True when SwiftMath can parse `latex` into a math list without error.
    /// Used to choose the SwiftMath path vs. the Unicode fallback before the
    /// `MTMathUILabel` is ever mounted, so failures never reach the screen.
    static func isRenderable(_ latex: String) -> Bool {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let key = trimmed as NSString
        if let cached = renderableCache.object(forKey: key) {
            return cached.boolValue
        }

        var error: NSError?
        let mathList = MTMathListBuilder.build(fromString: trimmed, error: &error)
        let renderable = error == nil && mathList != nil
        renderableCache.setObject(NSNumber(value: renderable), forKey: key)
        return renderable
    }
}

/// Fenced-code languages that should render as display math rather than source
/// code (e.g. ```math, ```latex, ```tex). Models sometimes wrap a standalone
/// equation in a math fence instead of `$$…$$`; those reach the renderer as a
/// code block, so we re-route the math ones (parity-plus over Hermes WebUI,
/// which shows these as code).
enum MathFenceLanguage {
    static let languages: Set<String> = ["math", "latex", "tex"]

    /// True when a fenced code block's info string names a math language.
    static func matches(_ language: String?) -> Bool {
        guard let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: language) else {
            return false
        }
        return languages.contains(normalized)
    }
}

/// Wraps SwiftMath's `MTMathUILabel` (a UIKit view) for use in SwiftUI.
/// Sized to its intrinsic content so long equations scroll horizontally in the
/// surrounding `ScrollView` instead of clipping.
private struct SwiftMathLabelView: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.textAlignment = .left
        // We pick the fallback view for unparseable input, so the inline red
        // error should never appear.
        label.displayErrorInline = false
        label.contentInsets = .zero
        configure(label)
        return label
    }

    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        configure(uiView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        uiView.intrinsicContentSize
    }

    /// Applies the current inputs, skipping no-op writes so repeated SwiftUI
    /// updates (e.g. during streaming) don't force needless re-typesetting.
    private func configure(_ label: MTMathUILabel) {
        if label.fontSize != fontSize {
            label.fontSize = fontSize
        }

        let textColor = Self.resolvedTextColor(for: colorScheme)
        if label.textColor != textColor {
            label.textColor = textColor
        }

        if label.latex != latex {
            label.latex = latex
        }
    }

    /// Resolves the dynamic label color against the SwiftUI color scheme so the
    /// Core Graphics-drawn math matches the surrounding text in light and dark.
    private static func resolvedTextColor(for colorScheme: ColorScheme) -> MTColor {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }
}

// MarkdownUI draws inline images as Text attachments. SwiftMath supplies their
// intrinsic size and baseline; paragraphs and lists retain their native flow.
struct InlineMathImageProvider: InlineImageProvider {
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    let scale: CGFloat
    var fallback: any InlineImageProvider = DefaultInlineImageProvider.default
    var tintImages = false

    func image(with url: URL, label: String) async throws -> Image {
        guard let latex = InlineMathSource.latex(from: url) else {
            return try await fallback.image(with: url, label: label)
        }
        try Task.checkCancellation()
        let image = try await InlineMathImageCache.shared.image(
            latex: latex, fontSize: fontSize, dark: colorScheme == .dark, scale: scale
        )
        try Task.checkCancellation()
        return tintImages ? Image(uiImage: image).renderingMode(.template) : Image(uiImage: image)
    }
}

enum InlineMathSource {
    static let marker = "hermex-math:///"

    static func latex(from url: URL) -> String? {
        guard url.scheme == "hermex-math", url.host == nil || url.host == "" else { return nil }
        let encoded = String(url.path.dropFirst())
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: encoded), data.count <= 512 else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

/// Serializes SwiftMath work off the main actor. One bounded cache serves every
/// Markdown consumer; keys include all raster inputs, never a streaming reply.
actor InlineMathImageCache {
    static let shared = InlineMathImageCache()
    // NSCache is thread-safe. Warm reads must not hop through the actor and
    // publish another view update on each token; only cold rendering is isolated.
    nonisolated(unsafe) private let storage = NSCache<NSString, UIImage>()
    private(set) var renderCount = 0

    init() {
        storage.countLimit = 256
        storage.totalCostLimit = 16 * 1024 * 1024
    }

    nonisolated func cachedImage(latex: String, fontSize: CGFloat, dark: Bool, scale: CGFloat) -> UIImage? {
        storage.object(forKey: "\(fontSize)|\(dark)|\(scale)|\(latex)" as NSString)
    }

    func image(latex: String, fontSize: CGFloat, dark: Bool, scale: CGFloat) throws -> UIImage {
        try Task.checkCancellation()
        let key = "\(fontSize)|\(dark)|\(scale)|\(latex)" as NSString
        if let cached = storage.object(forKey: key) { return cached }
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: .text, textAlignment: .left)
        let (error, rendered, layout) = math.asImage()
        let image: UIImage
        if error == nil, let rendered, let layout {
            let scaled: UIImage
            if rendered.scale == scale {
                scaled = rendered
            } else {
                scaled = UIGraphicsImageRenderer(size: rendered.size, format: format).image { _ in
                    rendered.draw(at: .zero)
                }
            }
            image = scaled.withBaselineOffset(fromBottom: layout.descent)
        } else {
            // Unknown commands remain readable source, never SwiftMath's error UI.
            let source = "$" + latex + "$" as NSString
            let font = UIFont.systemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let bounds = source.boundingRect(with: CGSize(width: 2048, height: 2048), options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            let size = CGSize(width: max(1, ceil(bounds.width)), height: max(1, ceil(bounds.height)))
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: size), withAttributes: attributes)
            }.withBaselineOffset(fromBottom: -font.descender)
        }
        try Task.checkCancellation()
        renderCount += 1
        storage.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * scale * scale * 4))
        return image
    }
}

private struct ContainsInlineMathKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var containsInlineMath: Bool {
        get { self[ContainsInlineMathKey.self] }
        set { self[ContainsInlineMathKey.self] = newValue }
    }
}

/// Adapts only math-bearing inline leaves. MarkdownUI still owns block layout,
/// list identity and every math-free leaf. Foundation retains nested inline
/// styles and links while SwiftUI Text attachments share the prose baseline.
struct MathMarkdownLabel<Label: View>: View {
    let content: MarkdownContent
    let label: Label
    var separator = "\n\n"
    var tableColumn: Int?
    var fontScale: Double = 1
    var weight: Font.Weight = .regular
    var tintImages = false
    @Environment(\.containsInlineMath) private var containsMath

    var body: some View {
        if containsMath {
            let markdown = content.renderMarkdown()
            if markdown.contains(InlineMathSource.marker)
                || MarkdownContentRenderingPolicy.hasTooManyInlineElements(markdown) {
                MathInlineText(markdown: markdown.trimmingCharacters(in: .newlines),
                               separator: separator, tableColumn: tableColumn,
                               fontScale: fontScale, weight: weight, tintImages: tintImages)
            } else {
                plainLabel
            }
        } else {
            plainLabel
        }
    }

    private var plainLabel: some View {
        label.responseSelectableText(content.renderPlainText().trimmingCharacters(in: .newlines),
                                     separator: separator, tableColumn: tableColumn)
    }
}

struct MathInlineText: View {
    let markdown: String
    var separator = "\n\n"
    var tableColumn: Int?
    var fontScale: Double = 1
    var weight: Font.Weight = .regular
    var tintImages = false
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (style: InlineMathImageStyle, images: [URL: Image])?

    private var request: InlineMathTextRequest {
        InlineMathTextRequest(markdown: markdown, fontSize: fontSize * fontScale,
                              dark: colorScheme == .dark, scale: displayScale, tintImages: tintImages, fontWeight: weight)
    }

    var body: some View {
        let currentRequest = request
        let images = loaded?.style == currentRequest.imageStyle ? loaded?.images ?? [:] : [:]
        let cached = try? currentRequest.cachedResult(images: images)
        let loadIdentity = cached == nil ? try? currentRequest.imageLoadIdentity() : nil
        Group {
            if let rendered = cached ?? (try? currentRequest.placeholder(images: images)) {
                rendered.text
                    .responseSelectableText(rendered.selectableText, separator: separator, tableColumn: tableColumn)
                    .accessibilityLabel(rendered.accessibilityText)
            }
        }
        .font(.system(size: fontSize * fontScale, weight: weight))
        .task(id: loadIdentity) {
            guard loadIdentity != nil else { return }
            try? await currentRequest.renderWithRetries(images: images) { result in
                loaded = (currentRequest.imageStyle, result.images)
            }
        }
    }
}

struct InlineMathTextResult {
    let text: Text
    let selectableText: String
    let accessibilityText: String
    let images: [URL: Image]
}

struct InlineMathImageStyle: Equatable {
    let fontSize: CGFloat
    let dark: Bool
    let scale: CGFloat
    let tintImages: Bool
}

struct InlineMathImageLoadIdentity: Equatable {
    struct Source: Equatable {
        let url: URL
        let label: String
    }
    let style: InlineMathImageStyle
    let sources: [Source]
}

struct InlineMathTextRequest: Equatable {
    let markdown: String
    let fontSize: CGFloat
    let dark: Bool
    let scale: CGFloat
    var tintImages = false
    var fontWeight: Font.Weight = .regular

    var imageStyle: InlineMathImageStyle {
        InlineMathImageStyle(fontSize: fontSize, dark: dark, scale: scale, tintImages: tintImages)
    }

    /// Token-only appends must not cancel an unchanged image download.
    func imageLoadIdentity() throws -> InlineMathImageLoadIdentity {
        let attributed = try parsed()
        var seen: Set<URL> = []
        let sources = attributed.runs.compactMap { run -> InlineMathImageLoadIdentity.Source? in
            guard run.link == nil, let url = run.imageURL, seen.insert(url).inserted else { return nil }
            return .init(url: url, label: String(attributed[run.range].characters))
        }
        return InlineMathImageLoadIdentity(style: imageStyle, sources: sources)
    }

    /// The usual streaming path: source changes, but every completed expression
    /// is already cached. Compose the new Text without async work or state writes.
    func cachedResult(images suppliedImages: [URL: Image] = [:]) throws -> InlineMathTextResult? {
        let attributed = try parsed()
        var images = suppliedImages
        for run in attributed.runs {
            guard run.link == nil, let url = run.imageURL, images[url] == nil else { continue }
            guard let latex = InlineMathSource.latex(from: url),
                  let image = InlineMathImageCache.shared.cachedImage(latex: latex, fontSize: fontSize, dark: dark, scale: scale) else {
                return nil
            }
            images[url] = tintImages ? Image(uiImage: image).renderingMode(.template) : Image(uiImage: image)
        }
        return compose(attributed, images: images)
    }

    /// Always compose current prose, retaining any already available attachments.
    func placeholder(images suppliedImages: [URL: Image] = [:]) throws -> InlineMathTextResult {
        let attributed = try parsed()
        var images = suppliedImages
        for run in attributed.runs {
            guard let url = run.imageURL, images[url] == nil,
                  let latex = InlineMathSource.latex(from: url),
                  let image = InlineMathImageCache.shared.cachedImage(latex: latex, fontSize: fontSize, dark: dark, scale: scale) else { continue }
            images[url] = tintImages ? Image(uiImage: image).renderingMode(.template) : Image(uiImage: image)
        }
        return compose(attributed, images: images)
    }

    /// Retry missing assets without refetching successes. The owning view task
    /// cancels both provider work and backoff when its assets change or it leaves.
    @MainActor
    func renderWithRetries(
        provider: (any InlineImageProvider)? = nil,
        images: [URL: Image] = [:],
        beforeRetry: (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 8))
        },
        didRender: (InlineMathTextResult) -> Void
    ) async throws {
        var available = images
        for attempt in 0..<3 {
            if attempt > 0 { try await beforeRetry(attempt) }
            try Task.checkCancellation()
            let result = try await render(provider: provider, images: available)
            try Task.checkCancellation()
            available = result.images
            didRender(result)
            if try cachedResult(images: available) != nil { return }
        }
    }

    @MainActor
    func render(provider suppliedProvider: (any InlineImageProvider)? = nil, images suppliedImages: [URL: Image] = [:]) async throws -> InlineMathTextResult {
        try Task.checkCancellation()
        let attributed = try parsed()
        let provider = suppliedProvider ?? InlineMathImageProvider(fontSize: fontSize, colorScheme: dark ? .dark : .light, scale: scale, tintImages: tintImages)
        var images = suppliedImages
        for run in attributed.runs {
            guard run.link == nil, let url = run.imageURL, images[url] == nil else { continue }
            try Task.checkCancellation()
            do {
                images[url] = try await provider.image(with: url, label: String(attributed[run.range].characters))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed ordinary image must not remove the sentence or equations.
                // Its alt text remains the fallback, as on the normal Markdown path.
            }
        }
        try Task.checkCancellation()
        return compose(attributed, images: images)
    }

    func parsed() throws -> AttributedString {
        // Foundation drops image attributes inside links. Recover image attributes
        // from the parser's source spans without parsing Markdown delimiters here.
        var previous: UInt8 = 0
        let mayContainLink = markdown.utf8.contains { byte in
            defer { previous = byte }
            return byte == 0x5B && previous != 0x21 // An opening bracket outside image syntax.
        }
        guard mayContainLink else {
            return try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        }
        let source = markdown
        var attributed = try AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true
        ))
        let bytes = Array(source.utf8)
        let lineStarts = [0] + bytes.indices.compactMap { bytes[$0] == 0x0A ? $0 + 1 : nil }
        for run in Array(attributed.runs).reversed() {
            guard run.link != nil, run.imageURL == nil, let position = run.markdownSourcePosition,
                  lineStarts.indices.contains(position.startLine - 1),
                  lineStarts.indices.contains(position.endLine - 1) else { continue }
            let start = lineStarts[position.startLine - 1] + position.startColumn - 1
            let end = lineStarts[position.endLine - 1] + position.endColumn
            guard start >= 0, end <= bytes.count, start < end else { continue }
            let imageSource = String(decoding: bytes[start..<end], as: UTF8.self)
            guard imageSource.contains("!["),
                  var label = try? AttributedString(markdown: imageSource),
                  label.runs.contains(where: { $0.imageURL != nil }) else { continue }
            label.link = run.link
            attributed.replaceSubrange(run.range, with: label)
        }
        return attributed
    }

    private func compose(_ attributed: AttributedString, images: [URL: Image]) -> InlineMathTextResult {
        // Prose runs share one `Text`: a `+` per run nests as deep as the paragraph is long.
        var text = Text("")
        var prose = AttributedString()
        var selectable = ""
        var accessible = ""
        var retainedImages: [URL: Image] = [:]
        for run in attributed.runs {
            if let url = run.imageURL {
                let alt = InlineMathSource.latex(from: url) ?? String(attributed[run.range].characters)
                let attachment: Text
                if let link = run.link {
                    // SwiftUI drops links on interpolated image attachments.
                    // Keep the destination usable with readable source/alt text.
                    var linked = AttributedString(alt)
                    linked.link = link
                    attachment = Text(linked)
                } else {
                    retainedImages[url] = images[url]
                    attachment = images[url].map { Text($0) } ?? Text(verbatim: alt)
                }
                if !prose.characters.isEmpty { text = text + Text(prose) }
                prose = AttributedString()
                text = text + attachment.customAttribute(ResponseSelectionImageAttribute())
                accessible += alt
            } else {
                var span = AttributedString(attributed[run.range])
                if run.inlinePresentationIntent?.contains(.code) == true {
                    span.font = .system(size: fontSize * ChatMarkdownInlineStyle.codeFontScale, weight: fontWeight, design: .monospaced)
                    span.backgroundColor = ChatMarkdownInlineStyle.codeBackground(dark: dark)
                }
                prose.append(span)
                let plain = String(span.characters)
                selectable += plain
                accessible += plain
            }
        }
        if !prose.characters.isEmpty { text = text + Text(prose) }
        return InlineMathTextResult(text: text, selectableText: selectable, accessibilityText: accessible, images: retainedImages)
    }
}
