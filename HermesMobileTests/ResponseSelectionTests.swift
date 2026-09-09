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
        let rendered = expectation(description: "SwiftUI boundary rendered")
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            rendered.fulfill()
        }
        await fulfillment(of: [rendered], timeout: 5)
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
        let markdown = """
        # Heading

        First **paragraph** with a [link](https://example.com).

        - List entry
        - Another entry

        ```
        let value = 1
        ```

        $$x^2$$

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
        let rendered = expectation(description: "Markdown laid out and drawn")
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            rendered.fulfill()
        }
        await fulfillment(of: [rendered], timeout: 5)
        controller.input.selectAll(nil)
        let text = try XCTUnwrap(controller.input.text(in: XCTUnwrap(controller.input.selectedTextRange)))
        for expected in ["Heading", "First paragraph with a link.", "List entry", "Another entry", "let value = 1", "Column", "Value", "Row", "Cell"] {
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

        let rendered = expectation(description: "Hosted response laid out and drawn")
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            rendered.fulfill()
        }
        await fulfillment(of: [rendered], timeout: 5)

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
        let rendered = expectation(description: "Unicode text rendered")
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            rendered.fulfill()
        }
        await fulfillment(of: [rendered], timeout: 5)
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
                ForEach(messages) { MessageBubbleView(message: $0) }
            }
            .padding(12)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await renderFrames()
        let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first)
        let originalHeight = scroll.contentSize.height
        let leaves = descendants(host.view, of: ResponseSelectionLeafView.self)
        XCTAssertGreaterThan(leaves.count, 100, "The fixture must materialize offscreen text too")
        let collected = leaves.filter { !($0.geometry?.glyphs.isEmpty ?? true) }
        XCTAssertLessThan(collected.count, leaves.count / 2, "Scrolling must not rasterize selection text throughout the transcript")
        try assertSelectable(message: messages[0], in: host.view)

        scroll.setContentOffset(CGPoint(x: 0, y: originalHeight - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        await renderFrames()
        try assertSelectable(message: messages[39], in: host.view)
        XCTAssertEqual(scroll.contentSize.height, originalHeight, accuracy: 1, "Enabling selection must not change text layout")

        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await renderFrames()
        try assertSelectable(message: messages[0], in: host.view)
        XCTAssertEqual(scroll.contentSize.height, originalHeight, accuracy: 1)
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

    private func renderFrames() async {
        let rendered = expectation(description: "Visibility and text rendering committed")
        let driver = ResponseSelectionFrameDriver { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }
}

@MainActor
private final class ResponseSelectionFrameDriver: NSObject {
    private let completion: () -> Void
    private var link: CADisplayLink?
    private var frames = 0
    init(completion: @escaping () -> Void) { self.completion = completion }
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() {
        frames += 1
        if frames == 3 { stop(); completion() }
    }
}
