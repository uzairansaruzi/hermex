import SwiftUI
import UIKit

/// One native selection document around the existing response layout. Text leaves
/// supply their actual glyph geometry; images, equations and controls never register.
struct ResponseTextSelection<Content: View>: UIViewControllerRepresentable {
    let identity: String
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> ResponseSelectionController {
        ResponseSelectionController()
    }

    func updateUIViewController(_ controller: ResponseSelectionController, context: Context) {
        if controller.identity != identity {
            controller.input.selectedTextRange = nil
            controller.identity = identity
        }
        controller.host.rootView = AnyView(content()
            .responseSelectionDocument(controller.scope)
            .textSelection(.disabled)
            .environment(\.self, environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: ResponseSelectionController, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiViewController.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

final class ResponseSelectionController: UIViewController {
    let input = ResponseSelectionInput()
    lazy var scope = ResponseSelectionScope(input: input)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var identity = ""

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

/// The hosted SwiftUI tree must not retain its containing UIKit view.
final class ResponseSelectionScope {
    weak var input: ResponseSelectionInput?
    init(input: ResponseSelectionInput) { self.input = input }
}

private struct ResponseSelectionScopeKey: EnvironmentKey {
    static let defaultValue: ResponseSelectionScope? = nil
}

private struct ResponseSelectionOrderKey: PreferenceKey {
    static let defaultValue: [UUID] = []
    static func reduce(value: inout [UUID], nextValue: () -> [UUID]) {
        value += nextValue()
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
                input?.leafOrder = order
            }
    }
}

extension View {
    /// Attach only to a leaf containing one resolved Text, not its block container.
    func responseSelectableText(_ text: String, separator: String = "\n") -> some View {
        modifier(ResponseSelectionLeaf(text: text, separator: separator))
    }
}

private struct ResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    @Environment(\.responseSelectionScope) private var scope

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.modifier(RegisteredResponseSelectionLeaf(text: text, separator: separator, scope: scope))
        } else {
            content
        }
    }
}

/// Allocate glyph storage only for completed responses, never the streaming path.
private struct RegisteredResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    let scope: ResponseSelectionScope
    @State private var geometry = ResponseGlyphGeometry()
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .textRenderer(ResponseSelectionRenderer(geometry: geometry))
            .background(ResponseSelectionMarker(scope: scope, id: id, text: text, separator: separator, geometry: geometry))
            .preference(key: ResponseSelectionOrderKey.self, value: [id])
    }
}

struct ResponseSelectionGlyph {
    let range: NSRange
    let rect: CGRect
    let rightToLeft: Bool
}

/// TextRenderer can draw off the main actor. Geometry is published without
/// invalidating SwiftUI state or scheduling a second rendering pass.
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

private struct ResponseSelectionRenderer: TextRenderer {
    let geometry: ResponseGlyphGeometry

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let indices = layout.flatMap { $0.flatMap { $0.characterIndices } }
        guard let start = indices.min() else { return }
        var glyphs: [ResponseSelectionGlyph] = []
        for line in layout {
            context.draw(line)
            for run in line {
                for slice in run {
                    guard let lower = slice.characterIndices.min(), let upper = slice.characterIndices.max() else { continue }
                    glyphs.append(ResponseSelectionGlyph(
                        range: NSRange(location: start.distance(to: lower), length: lower.distance(to: upper) + 1),
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
        view.geometry = geometry
        view.rightToLeft = layoutDirection == .rightToLeft
    }
}

final class ResponseSelectionLeafView: UIView {
    var id = UUID()
    var text = ""
    var separator = "\n"
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
