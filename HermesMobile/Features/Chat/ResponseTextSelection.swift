import SwiftUI
import UIKit

struct ResponseTextSelection<Content: View>: UIViewControllerRepresentable {
    let identity: String
    var inputs: AnyHashable?
    var collectsGlyphs = true
    var onAskHermex: ((String) -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.previewsHermesDocuments) private var previewsHermesDocuments
    @Environment(\.transcriptHTMLReportLoader) private var htmlReportLoader
    @Environment(\.markdownTableEdgeFadeColor) private var tableEdgeFadeColor
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @Environment(\.openURL) private var openURL
    @State private var contentHeight: CGFloat = 0

    func makeUIViewController(context: Context) -> ResponseSelectionController {
        ResponseSelectionController()
    }

    func updateUIViewController(_ controller: ResponseSelectionController, context: Context) {
        RenderProbe.hit(.responseSelectionUpdate)
        controller.scope.collectsGlyphs = collectsGlyphs
        controller.input.onAskHermex = onAskHermex
        controller.openURL = openURL
        if controller.identity != identity {
            controller.input.selectedTextRange = nil
            controller.identity = identity
        }
        _ = contentHeight
        let rendering = ResponseSelectionRendering(identity: identity, inputs: inputs, environment: ResponseSelectionEnvironment(
            colorScheme: colorScheme,
            layoutDirection: layoutDirection,
            dynamicTypeSize: dynamicTypeSize,
            displayScale: displayScale,
            locale: locale,
            previewsHermesDocuments: previewsHermesDocuments,
            htmlReportLoader: htmlReportLoader,
            tableEdgeFadeColor: tableEdgeFadeColor,
            chatDisclosureToggled: chatDisclosureToggled
        ))
        guard controller.rendering != rendering else { return }
        controller.rendering = rendering
        let contentHeight = $contentHeight
        let environment = rendering.environment
        controller.host.rootView = AnyView(content()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight.wrappedValue = $0 }
            .responseSelectionDocument(controller.scope)
            .textSelection(.disabled)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.locale, environment.locale)
            .environment(\.previewsHermesDocuments, environment.previewsHermesDocuments)
            .environment(\.transcriptHTMLReportLoader, environment.htmlReportLoader)
            .environment(\.markdownTableEdgeFadeColor, environment.tableEdgeFadeColor)
            .environment(\.chatDisclosureToggled, environment.chatDisclosureToggled)
            .environment(\.openURL, controller.forwardedOpenURL))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: ResponseSelectionController, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiViewController.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

struct ResponseSelectionEnvironment: Equatable {
    let colorScheme: ColorScheme
    let layoutDirection: LayoutDirection
    let dynamicTypeSize: DynamicTypeSize
    let displayScale: CGFloat
    let locale: Locale
    let previewsHermesDocuments: Bool
    let htmlReportLoader: TranscriptHTMLReportLoader?
    let tableEdgeFadeColor: Color?
    let chatDisclosureToggled: ChatDisclosureToggleAction
}

struct ResponseSelectionRendering: Equatable {
    let identity: String
    let inputs: AnyHashable?
    let environment: ResponseSelectionEnvironment
}

final class ResponseSelectionController: UIViewController {
    let input = ResponseSelectionInput()
    lazy var scope = ResponseSelectionScope(input: input)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var identity = ""
    var rendering: ResponseSelectionRendering?
    var openURL = OpenURLAction { _ in .systemAction }
    private(set) lazy var forwardedOpenURL = OpenURLAction { [weak self] url in
        guard let self else { return .systemAction }
        openURL(url)
        return .handled
    }

    override func loadView() {
        view = input
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(host.view)
        host.view.addInteraction(input.selectionInteraction)
        input.accessibilityElements = [host.view!]
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: input.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: input.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@Observable
final class ResponseSelectionScope {
    var collectsGlyphs = true
    weak var input: ResponseSelectionInput?
    init(input: ResponseSelectionInput) { self.input = input }
}

private struct ResponseSelectionScopeKey: EnvironmentKey {
    static let defaultValue: ResponseSelectionScope? = nil
}

private indirect enum ResponseSelectionOrder: Equatable {
    case empty
    case leaf(UUID)
    case pair(ResponseSelectionOrder, ResponseSelectionOrder)

    var ids: [UUID] {
        var ids: [UUID] = []
        collect(into: &ids)
        return ids
    }

    private func collect(into ids: inout [UUID]) {
        switch self {
        case .empty: break
        case .leaf(let id): ids.append(id)
        case .pair(let first, let second):
            first.collect(into: &ids)
            second.collect(into: &ids)
        }
    }
}

private struct ResponseSelectionOrderKey: PreferenceKey {
    static let defaultValue = ResponseSelectionOrder.empty
    static func reduce(value: inout ResponseSelectionOrder, nextValue: () -> ResponseSelectionOrder) {
        let next = nextValue()
        if case .empty = next { return }
        if case .empty = value { value = next } else { value = .pair(value, next) }
    }
}

extension EnvironmentValues {
    var responseSelectionScope: ResponseSelectionScope? {
        get { self[ResponseSelectionScopeKey.self] }
        set { self[ResponseSelectionScopeKey.self] = newValue }
    }
}

extension View {
    func responseSelectionDocument(_ scope: ResponseSelectionScope) -> some View {
        environment(\.responseSelectionScope, scope)
            .onPreferenceChange(ResponseSelectionOrderKey.self) { [weak input = scope.input] order in
                input?.leafOrder = order.ids
            }
    }
}

extension View {
    func responseSelectableText(_ text: String, separator: String = "\n", tableColumn: Int? = nil) -> some View {
        modifier(ResponseSelectionLeaf(text: text, separator: separator, tableColumn: tableColumn))
    }
}

private struct ResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    let tableColumn: Int?
    @Environment(\.responseSelectionScope) private var scope

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.modifier(RegisteredResponseSelectionLeaf(text: text, separator: separator, tableColumn: tableColumn, scope: scope))
        } else {
            content
        }
    }
}

private struct RegisteredResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    let tableColumn: Int?
    let scope: ResponseSelectionScope
    @State private var geometry = ResponseGlyphGeometry()
    @State private var id = UUID()

    func body(content: Content) -> some View {
        Group {
            if scope.collectsGlyphs {
                content.textRenderer(ResponseSelectionRenderer(geometry: geometry))
            } else {
                content
            }
        }
        .background(ResponseSelectionMarker(scope: scope, id: id, text: text, separator: separator, tableColumn: tableColumn, geometry: geometry))
        .preference(key: ResponseSelectionOrderKey.self, value: .leaf(id))
    }
}

struct ResponseSelectionGlyph {
    let range: NSRange
    let rect: CGRect
    let rightToLeft: Bool
}

final class ResponseGlyphGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ResponseSelectionGlyph] = []

    var glyphs: [ResponseSelectionGlyph] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func replace(_ glyphs: [ResponseSelectionGlyph]) {
        lock.lock()
        storage = glyphs
        lock.unlock()
    }
}

struct ResponseSelectionImageAttribute: TextAttribute {}

private struct ResponseSelectionRenderer: TextRenderer {
    let geometry: ResponseGlyphGeometry

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let indices = layout.flatMap { $0.flatMap { $0.characterIndices } }
        guard let start = indices.min() else { return }
        let imageOffsets = layout.flatMap { line in
            line.filter { $0[ResponseSelectionImageAttribute.self] != nil }
                .flatMap { $0.characterIndices }
        }.map { start.distance(to: $0) }.sorted()
        func selectableOffset(_ raw: Int) -> Int {
            var lower = 0
            var upper = imageOffsets.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if imageOffsets[middle] < raw { lower = middle + 1 } else { upper = middle }
            }
            return raw - lower
        }
        var glyphs: [ResponseSelectionGlyph] = []
        for line in layout {
            context.draw(line)
            for run in line where run[ResponseSelectionImageAttribute.self] == nil {
                for slice in run {
                    guard let lower = slice.characterIndices.min(), let upper = slice.characterIndices.max() else { continue }
                    let location = selectableOffset(start.distance(to: lower))
                    let end = selectableOffset(start.distance(to: upper) + 1)
                    glyphs.append(ResponseSelectionGlyph(
                        range: NSRange(location: location, length: end - location),
                        rect: slice.typographicBounds.rect,
                        rightToLeft: run.layoutDirection == .rightToLeft
                    ))
                }
            }
        }
        geometry.replace(glyphs)
    }
}

private struct ResponseSelectionMarker: UIViewRepresentable {
    let scope: ResponseSelectionScope
    let id: UUID
    let text: String
    let separator: String
    let tableColumn: Int?
    let geometry: ResponseGlyphGeometry
    @Environment(\.layoutDirection) private var layoutDirection

    func makeUIView(context: Context) -> ResponseSelectionLeafView {
        let view = ResponseSelectionLeafView()
        view.isUserInteractionEnabled = false
        scope.input?.leaves.add(view)
        return view
    }

    func updateUIView(_ view: ResponseSelectionLeafView, context: Context) {
        view.id = id
        view.text = text
        view.separator = separator
        view.tableColumn = tableColumn
        view.geometry = geometry
        view.rightToLeft = layoutDirection == .rightToLeft
    }
}

final class ResponseSelectionLeafView: UIView {
    var id = UUID()
    var text = ""
    var separator = "\n"
    var tableColumn: Int?
    var geometry: ResponseGlyphGeometry?
    var rightToLeft = false
}

final class ResponseTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class ResponseTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range }
    override var start: UITextPosition { ResponseTextPosition(range.location) }
    override var end: UITextPosition { ResponseTextPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

final class ResponseSelectionRect: UITextSelectionRect {
    let glyph: ResponseSelectionGlyph
    let starts: Bool
    let ends: Bool
    init(_ glyph: ResponseSelectionGlyph, starts: Bool, ends: Bool) {
        self.glyph = glyph
        self.starts = starts
        self.ends = ends
    }
    override var rect: CGRect { glyph.rect }
    override var writingDirection: NSWritingDirection { glyph.rightToLeft ? .rightToLeft : .leftToRight }
    override var containsStart: Bool { starts }
    override var containsEnd: Bool { ends }
    override var isVertical: Bool { false }
}

private struct ResponseTextSelectionPolicy: ViewModifier {
    @Environment(\.responseSelectionScope) private var scope
    @ViewBuilder func body(content: Content) -> some View {
        if scope == nil { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}

extension View {
    func responseTextSelectionPolicy() -> some View { modifier(ResponseTextSelectionPolicy()) }
}
