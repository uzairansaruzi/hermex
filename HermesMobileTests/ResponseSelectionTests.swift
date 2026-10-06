import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class ResponseSelectionTests: XCTestCase {
    func testAskHermexReturnsExactSelectionAndClearsIt() {
        let input = ResponseSelectionInput()
        let controller = UIViewController()
        controller.view = input
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        input.leafOrder = []
        let leaf = ResponseSelectionLeafView()
        leaf.text = "  First line\nSecond line  "
        input.addSubview(leaf)
        input.leaves.add(leaf)
        input.selectedTextRange = ResponseTextRange(
            NSRange(location: 0, length: leaf.text.utf16.count)
        )
        XCTAssertFalse(input.canPerformAction(#selector(input.askHermex(_:)), withSender: nil), "No composer to quote into, no Ask Hermex")
        var passage: String?
        input.onAskHermex = { passage = $0 }

        XCTAssertTrue(input.canPerformAction(#selector(input.askHermex(_:)), withSender: nil))
        input.askHermex(nil)

        XCTAssertEqual(passage, "  First line\nSecond line  ")
        XCTAssertNil(input.selectedTextRange)
    }

    func testSwiftUIResponseBoundaryRegistersItsHostedText() async throws {
        let controller = UIHostingController(rootView: ResponseTextSelection(identity: "response") {
            Text("A completed response").responseSelectableText("A completed response")
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        func selectionInput(in view: UIView) -> ResponseSelectionInput? {
            if let input = view as? ResponseSelectionInput { return input }
            return view.subviews.lazy.compactMap { selectionInput(in: $0) }.first
        }
        let input = try XCTUnwrap(selectionInput(in: controller.view))
        input.selectAll(nil)
        let range = try XCTUnwrap(input.selectedTextRange)
        XCTAssertEqual(input.text(in: range), "A completed response\n")
        let rect = try XCTUnwrap(input.selectionRects(for: range).first).rect
        XCTAssertTrue(input.interactionShouldBegin(UITextInteraction(for: .nonEditable), at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertFalse(input.isAccessibilityElement)
        XCTAssertFalse(try XCTUnwrap(input.accessibilityElements).isEmpty)
    }

    func testRealMarkdownRegistersHeadingsListsCodeAndTableButNotEquations() async throws {
        _ = try await InlineMathImageCache.shared.image(latex: "M_S", fontSize: 16, dark: false, scale: 3)
        let markdown = """
        # Heading

        First **paragraph** with a [link](https://example.com).

        - List entry
        - Another entry

        ```
        let value = 1
        ```

        $$x^2$$

        Inline $M_S$ after.

        | Column | Value |
        | --- | --- |
        | Row | Cell |
        """
        let controller = ResponseSelectionController()
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(MarkdownRenderer(content: markdown)
            .responseSelectionDocument(controller.scope))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        await render(window)
        controller.input.selectAll(nil)
        let text = try XCTUnwrap(controller.input.text(in: XCTUnwrap(controller.input.selectedTextRange)))
        for expected in ["Heading", "First paragraph with a link.", "List entry", "Another entry", "let value = 1", "Column", "Value", "Row", "Cell", "Inline  after."] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected) in \(text)")
        }
        XCTAssertTrue(text.contains("Column\tValue\nRow\tCell\n\n"), text)
        XCTAssertFalse(text.contains("x^2"))
        XCTAssertFalse(text.contains("x²"))
        XCTAssertFalse(text.contains("Copy code"))
        XCTAssertFalse(controller.input.selectionRects(for: try XCTUnwrap(controller.input.selectedTextRange)).isEmpty)
    }

    func testSelectionSpansTextLeavesAndExcludesOtherViewsAndResponses() async throws {
        let controller = ResponseSelectionController()
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(VStack(alignment: .leading) {
            Text("First paragraph").responseSelectableText("First paragraph", separator: "\n\n")
            Text("An equation image").accessibilityLabel("Equation")
            Text("let value = 1").font(.system(.body, design: .monospaced))
                .responseSelectableText("let value = 1")
        }.responseSelectionDocument(controller.scope))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        await render(window)

        let input = controller.input
        input.selectAll(nil)
        let selection = try XCTUnwrap(input.selectedTextRange)
        XCTAssertEqual(input.text(in: selection), "First paragraph\n\nlet value = 1\n")
        XCTAssertFalse(input.selectionRects(for: selection).isEmpty)
        XCTAssertTrue(input.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))

        let another = ResponseSelectionInput()
        XCTAssertFalse(another.hasText)
        XCTAssertNil(another.selectedTextRange)
    }

    func testRenderedGlyphOffsetsMatchUTF16IncludingEmojiAndCombiningCharacters() async throws {
        let text = "A 👩🏽‍💻 é שלום"
        let controller = ResponseSelectionController()
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(Text(verbatim: text).responseSelectableText(text)
            .responseSelectionDocument(controller.scope))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        let leaf = try XCTUnwrap(controller.input.leaves.allObjects.first)
        let glyphs = try XCTUnwrap(leaf.geometry).glyphs
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertEqual(glyphs.map { NSMaxRange($0.range) }.max(), text.utf16.count)
        XCTAssertTrue(glyphs.contains(where: \.rightToLeft))
        let emoji = try XCTUnwrap(controller.input.characterRange(byExtending: ResponseTextPosition(2), in: .right))
        XCTAssertEqual(controller.input.text(in: emoji), "👩🏽‍💻")
    }
}

@MainActor
final class ResponseSelectionVisibilityTests: XCTestCase {
    func testOffscreenResponsesDeferGlyphRenderingAndRemainSelectableWhenScrolledIntoView() async throws {
        let messages = (0..<40).map { index in
            ChatMessage(role: "assistant", content: String(repeating: "Response \(index). Text that wraps onto several lines.\n\n", count: index == 0 ? 30 : 6), timestamp: 1, messageId: "selection-\(index)")
        }
        let host = UIHostingController(rootView: ScrollView {
            VStack {
                ForEach(messages) { MessageBubbleView(message: $0, transcriptMediaCacheNamespace: "https://webui.example|test") }
            }
            .padding(12)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await renderVisibleRows(window)
        let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first)
        let originalHeight = scroll.contentSize.height
        let leaves = descendants(host.view, of: ResponseSelectionLeafView.self)
        XCTAssertGreaterThan(leaves.count, 100, "The fixture must materialize offscreen text too")
        let collected = leaves.filter { !($0.geometry?.glyphs.isEmpty ?? true) }
        XCTAssertLessThan(collected.count, leaves.count / 2, "Scrolling must not rasterize selection text throughout the transcript")
        try assertSelectable(message: messages[0], in: host.view)

        scroll.setContentOffset(CGPoint(x: 0, y: originalHeight - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        await renderVisibleRows(window)
        try assertSelectable(message: messages[39], in: host.view)
        XCTAssertEqual(scroll.contentSize.height, originalHeight, accuracy: 1, "Enabling selection must not change text layout")

        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await renderVisibleRows(window)
        try assertSelectable(message: messages[0], in: host.view)
        XCTAssertEqual(scroll.contentSize.height, originalHeight, accuracy: 1)
    }

    /// A lazy transcript places rows it has not realized from their measured
    /// height, so a selection document that measures short strands the scroll.
    func testLazyTranscriptScrollsToASelectableRowItHasNotRealized() async throws {
        let rows = (0..<60).map { index in
            String(repeating: "Lazy row \(index). Text that wraps onto several lines.\n\n", count: 8)
        }
        let host = UIHostingController(rootView: ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows.indices, id: \.self) { index in
                        ResponseTextSelection(identity: rows[index]) {
                            Text(rows[index]).responseSelectableText(rows[index])
                        }
                        .id(index)
                    }
                }
                .padding(12)
            }
            .task { proxy.scrollTo(rows.count - 1, anchor: .bottom) }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await renderVisibleRows(window)
        await renderVisibleRows(window)

        let last = try XCTUnwrap(descendants(host.view, of: ResponseSelectionLeafView.self).first { $0.text == rows[rows.count - 1] })
        let frame = last.convert(last.bounds, to: window)
        XCTAssertGreaterThan(frame.height, 100, "The row must keep its wrapped height")
        XCTAssertTrue(window.bounds.intersects(frame), "The scroll must land on the row, not on blank space")
        XCTAssertLessThanOrEqual(frame.maxY, window.bounds.maxY + 1, "The row's bottom edge must sit at the latest edge")
    }

    private func assertSelectable(message: ChatMessage, in view: UIView) throws {
        let text = try XCTUnwrap(message.content)
        let prefix = String(text.prefix(12))
        let leaf = try XCTUnwrap(descendants(view, of: ResponseSelectionLeafView.self).first { $0.text.hasPrefix(prefix) })
        var ancestor = leaf.superview
        while ancestor != nil && !(ancestor is ResponseSelectionInput) { ancestor = ancestor?.superview }
        let input = try XCTUnwrap(ancestor as? ResponseSelectionInput)
        input.selectAll(nil)
        let range = try XCTUnwrap(input.selectedTextRange)
        XCTAssertEqual(input.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines), text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(input.selectionRects(for: range).isEmpty, "Visible responses need real selection handles")
        input.selectedTextRange = nil
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    /// The first pass reports which rows are visible; the second redraws those
    /// rows with glyph collection on.
    private func renderVisibleRows(_ window: UIWindow) async {
        await render(window)
        await render(window)
    }
}

/// Lays out and draws `window` once, after one main-queue turn so SwiftUI can
/// commit pending state. There is no deadline: both calls are synchronous, and
/// the assertions that follow decide whether the pass rendered what they read.
/// Every pass draws because selection leaves collect glyphs only when text draws.
@MainActor
private func render(_ window: UIWindow) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    window.layoutIfNeeded()
    _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
}

extension ResponseSelectionTests {
    func testInlineMathBaselineAndSelectionLeaveAnImageGap() async throws {
        let result = try await InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "A $M_S$ Z"),
            fontSize: 16, dark: false, scale: 3
        ).render()
        let controller = ResponseSelectionController()
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(result.text.font(.system(size: 16))
            .responseSelectableText(result.selectableText)
            .responseSelectionDocument(controller.scope))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        controller.input.selectAll(nil)
        let range = try XCTUnwrap(controller.input.selectedTextRange)
        XCTAssertEqual(controller.input.text(in: range), "A  Z\n")
        let leaf = try XCTUnwrap(controller.input.leaves.allObjects.first)
        let glyphs = try XCTUnwrap(leaf.geometry).glyphs
        XCTAssertEqual(glyphs.map { NSMaxRange($0.range) }.max(), 4, "Images must not shift subsequent selectable character offsets")
        let a = try XCTUnwrap(glyphs.first { $0.range.location == 0 })
        let z = try XCTUnwrap(glyphs.first { $0.range.location == 3 })
        XCTAssertEqual(a.rect.minY, z.rect.minY, accuracy: 0.5, "Text on either side shares a baseline")
        XCTAssertGreaterThan(z.rect.minX - a.rect.maxX, 15, "Equation occupies a non-selectable inline gap")
    }

    func testInlineMathWrapsAtLargeTypeWithoutChangingSelection() async throws {
        let result = try await InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "Before $M_I = M_S^*$ after and more words."),
            fontSize: 32, dark: true, scale: 3
        ).render()
        let controller = ResponseSelectionController()
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(result.text.font(.system(size: 32))
            .frame(width: 220, alignment: .leading)
            .responseSelectableText(result.selectableText)
            .responseSelectionDocument(controller.scope))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 220, height: 500))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        controller.input.selectAll(nil)
        XCTAssertEqual(controller.input.text(in: try XCTUnwrap(controller.input.selectedTextRange)), "Before  after and more words.\n")
        let glyphs = try XCTUnwrap(controller.input.leaves.allObjects.first?.geometry).glyphs
        XCTAssertGreaterThan(Set(glyphs.map { Int($0.rect.minY.rounded()) }).count, 1, "Large text must wrap")
        XCTAssertEqual(glyphs.map { NSMaxRange($0.range) }.max(), result.selectableText.utf16.count)
    }
}

/// Comparative benchmark: report medians, never assert noisy wall-clock budgets.
/// This same test is run against baseline and final production sources.
/// PR CI skips it; run it by hand with
/// `scripts/test-sim <udid> --only HermesMobileTests/MathTranscriptPerformanceTests`.
@MainActor
final class MathTranscriptPerformanceTests: XCTestCase {
    func testRepresentativeTranscriptsAndIncrementalScroll() async throws {
        var results: [String: [Double]] = [:]
        for mode in ["math-free", "math-heavy", "long-stream"] {
            for sample in 0..<7 {
                let model = MathTranscriptBenchmarkModel()
                let paragraph = mode == "math-free"
                    ? "A normal response with **bold text**, a list and some ordinary prose.\n\n"
                    : #"The map $M_S$ keeps $K$ rows and $M_I = M_S^*$ restores them. Compare $(4,-2)$ and $(4,4)$."# + "\n\n"
                model.rows = (0..<20).map { "Response \($0).\n\n" + String(repeating: paragraph, count: 5) }
                model.tail = String(repeating: paragraph, count: mode == "long-stream" ? 60 : 2)
                let host = UIHostingController(rootView: MathTranscriptBenchmarkView(model: model))
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.rootViewController = host
                window.makeKeyAndVisible()
                await render(window)
                await render(window)
                let scroll = try XCTUnwrap(findScroll(host.view))
                XCTAssertGreaterThan(scroll.contentSize.height, 844)
                let start = CACurrentMediaTime()
                for step in 0..<12 {
                    model.tail += step.isMultiple(of: 3) ? paragraph : " next"
                    scroll.setContentOffset(CGPoint(x: 0, y: step.isMultiple(of: 2) ? 0 : max(0, scroll.contentSize.height - 844)), animated: false)
                    await render(window)
                    await render(window)
                }
                let elapsed = (CACurrentMediaTime() - start) * 1000
                if sample >= 2 { results[mode, default: []].append(elapsed) }
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        for mode in results.keys.sorted() {
            let samples = results[mode]!.sorted()
            print("MATH_TRANSCRIPT_BENCH \(mode) median_ms=\(samples[2]) samples=\(samples)")
        }
    }

    private func findScroll(_ view: UIView) -> UIScrollView? {
        (view as? UIScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
    }
}

@MainActor @Observable
private final class MathTranscriptBenchmarkModel {
    var rows: [String] = []
    var tail = ""
}

private struct MathTranscriptBenchmarkView: View {
    let model: MathTranscriptBenchmarkModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading) {
                ForEach(model.rows.indices, id: \.self) { index in
                    MarkdownRenderer(content: model.rows[index])
                }
                MarkdownRenderer(content: model.tail, isStreaming: true)
            }
            .padding(12)
        }
        .environment(\.allowsStreamedTextAnimation, false)
    }
}
