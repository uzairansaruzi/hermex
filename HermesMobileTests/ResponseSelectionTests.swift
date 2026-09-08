import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class ResponseSelectionTests: XCTestCase {
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
