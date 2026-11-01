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

/// Transcript media loads only once its leaf scrolls into view (#1370): the
/// transcript is an eager stack, so every row mounts when the chat opens.
@MainActor
final class TranscriptMediaVisibilityTests: XCTestCase {
    func testOffscreenMediaWaitsUntilItScrollsIntoView() async throws {
        let log = MediaLoadLog()
        let transcript = MediaTranscript(log: log, top: Self.mediaMessages("near"), bottom: Self.mediaMessages("far"))
        let near = ["/u/near.png", "/u/near.m4a", "/tmp/media/near-shot.png", "https://cdn.example/media/near-probe"]
        let far = ["/u/far.png", "/u/far.m4a", "/tmp/media/far-shot.png", "https://cdn.example/media/far-probe"]
        let nearLoads = near.map { log.expect($0) }
        let (window, scroll) = try await show(transcript)
        defer { window.isHidden = true; window.rootViewController = nil }

        // The visible reply's MEDIA sits in the selection host, so this also
        // proves the hosted fallback admits a reply that is on screen.
        await fulfillment(of: nearLoads, timeout: 5)
        await render(window)
        for path in far {
            XCTAssertEqual(log.calls[path, default: 0], 0, "\(path) loaded before it scrolled into view")
        }

        let farLoads = far.map { log.expect($0) }
        scrollToBottom(scroll)
        await renderVisibleRows(window)
        await fulfillment(of: farLoads, timeout: 5)
        for path in near + far {
            XCTAssertEqual(log.calls[path], 1, path)
        }
    }

    func testRemountRetriesACancelledLoadAndScrollingAwayKeepsIt() async throws {
        let log = MediaLoadLog()
        log.heldPath = "/u/near.m4a"
        let transcript = MediaTranscript(log: log, top: Self.mediaMessages("near"), bottom: [])
        let started = log.expect("/u/near.m4a")
        let (window, scroll) = try await show(transcript)
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [started], timeout: 5)

        // Removing the row cancels its held load, and mounting it again retries.
        let cancelled = log.expectFinish("/u/near.m4a")
        transcript.showsTop = false
        await renderVisibleRows(window)
        await fulfillment(of: [cancelled], timeout: 5)
        let retried = log.expect("/u/near.m4a")
        transcript.showsTop = true
        await renderVisibleRows(window)
        await fulfillment(of: [retried], timeout: 5)

        let finished = log.expectFinish("/u/near.m4a")
        scrollToBottom(scroll)
        await renderVisibleRows(window)
        log.releaseHeldLoads()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(log.cancelled["/u/near.m4a"], 1, "Scrolling away must not cancel the remounted row's load")
    }

    func testDetachedAudioWaitsForItsLoadKeyAfterScrollingIn() async throws {
        let log = MediaLoadLog()
        let transcript = MediaTranscript(log: log, top: [], bottom: Self.mediaMessages("far"))
        transcript.audioLoadKey = nil
        let (window, scroll) = try await show(transcript)
        defer { window.isHidden = true; window.rootViewController = nil }

        let image = log.expect("/u/far.png")
        scrollToBottom(scroll)
        await renderVisibleRows(window)
        await fulfillment(of: [image], timeout: 5)
        await render(window)
        XCTAssertEqual(log.calls["/u/far.m4a", default: 0], 0, "A detached chat's audio waits for the attach")

        let audio = log.expect("/u/far.m4a")
        transcript.audioLoadKey = 1
        await renderVisibleRows(window)
        await fulfillment(of: [audio], timeout: 5)
    }

    /// A user message with an image and an audio attachment, then a settled
    /// reply showing a MEDIA image and an extensionless remote MEDIA URL, which
    /// the reply probes through its data loader to learn what it is.
    private static func mediaMessages(_ name: String) -> [ChatMessage] {
        [
            ChatMessage(role: "user", content: "", timestamp: 1, messageId: "\(name)-user", attachments: [
                MessageAttachment(name: "\(name).png", path: "/u/\(name).png", mime: "image/png", isImage: true),
                MessageAttachment(name: "\(name).m4a", path: "/u/\(name).m4a", mime: "audio/mp4")
            ]),
            ChatMessage(role: "assistant", content: "Here: ![Shot](/tmp/media/\(name)-shot.png) MEDIA:https://cdn.example/media/\(name)-probe", timestamp: 1, messageId: "\(name)-reply")
        ]
    }

    private func show(_ transcript: MediaTranscript) async throws -> (UIWindow, UIScrollView) {
        let host = UIHostingController(rootView: MediaTranscriptView(transcript: transcript))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        await renderVisibleRows(window)
        let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first)
        return (window, scroll)
    }

    private func scrollToBottom(_ scroll: UIScrollView) {
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    /// The first pass reports which leaves are visible; the second admits them.
    private func renderVisibleRows(_ window: UIWindow) async {
        await render(window)
        await render(window)
    }
}

/// Counts every media load by path. A held path parks its loads until
/// `releaseHeldLoads()`, or until the load's task is cancelled.
@MainActor
private final class MediaLoadLog {
    private(set) var calls: [String: Int] = [:]
    private(set) var cancelled: [String: Int] = [:]
    var heldPath: String?
    private var started: [String: XCTestExpectation] = [:]
    private var finished: [String: XCTestExpectation] = [:]
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Fulfilled by the next load of `path`.
    func expect(_ path: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "load \(path)")
        started[path] = expectation
        return expectation
    }

    /// Fulfilled when the next load of `path` returns.
    func expectFinish(_ path: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "finish \(path)")
        finished[path] = expectation
        return expectation
    }

    func releaseHeldLoads() {
        let continuations = held.values
        held = [:]
        continuations.forEach { $0.resume() }
    }

    func load(_ path: String) async -> Data? {
        calls[path, default: 0] += 1
        started.removeValue(forKey: path)?.fulfill()
        if path == heldPath {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { held[id] = $0 }
            } onCancel: {
                Task { @MainActor in self.held.removeValue(forKey: id)?.resume() }
            }
            if Task.isCancelled { cancelled[path, default: 0] += 1 }
        }
        finished.removeValue(forKey: path)?.fulfill()
        return nil
    }
}

@MainActor @Observable
private final class MediaTranscript {
    let log: MediaLoadLog
    let top: [ChatMessage]
    let bottom: [ChatMessage]
    let namespace = "https://webui.example|visibility-\(UUID().uuidString)"
    var showsTop = true
    var audioLoadKey: Int? = 0

    init(log: MediaLoadLog, top: [ChatMessage], bottom: [ChatMessage]) {
        self.log = log
        self.top = top
        self.bottom = bottom
    }
}

/// An eager transcript like `ChatTranscriptView`'s: `top`, a screenful of text
/// several times over, then `bottom`.
private struct MediaTranscriptView: View {
    let transcript: MediaTranscript

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if transcript.showsTop {
                    ForEach(transcript.top) { bubble($0) }
                }
                ForEach(0..<12, id: \.self) { index in
                    bubble(ChatMessage(role: "assistant", content: String(repeating: "Filler \(index) that wraps onto several lines.\n\n", count: 6), timestamp: 1, messageId: "filler-\(index)"))
                }
                ForEach(transcript.bottom) { bubble($0) }
            }
            .padding(12)
        }
    }

    private func bubble(_ message: ChatMessage) -> MessageBubbleView {
        let log = transcript.log
        return MessageBubbleView(
            message: message,
            loadAttachmentImage: { await log.load($0) },
            attachmentAudio: AttachmentAudioSource(load: { await log.load($0) }, isHost: false, loadKey: transcript.audioLoadKey),
            loadTranscriptMediaImage: { await log.load($0.rawReference) },
            loadTranscriptMediaData: { await log.load($0.rawReference) },
            transcriptMediaCacheNamespace: transcript.namespace
        )
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
}

/// Grows after its first layout, like MarkdownUI's block margins and async highlighting.
private struct LateGrowingResponse: View {
    let onTextTop: (CGFloat) -> Void
    @State private var grown = false

    var body: some View {
        Text("Reply").responseSelectableText("Reply")
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }, action: onTextTop)
            .frame(maxWidth: .infinity, minHeight: grown ? 300 : 100, alignment: .topLeading)
            .task { grown = true }
    }
}

extension ResponseSelectionTests {
    func testRowsAroundAResponseStayClearWhenItGrowsAfterFirstLayout() async throws {
        var headerBottom: CGFloat = 0
        var textTop: CGFloat = 0
        var footerTop: CGFloat = 0
        let controller = UIHostingController(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 40)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
            ResponseTextSelection(identity: "response") {
                LateGrowingResponse { textTop = $0 }
            }
            Color.clear.frame(height: 20)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { footerTop = $0 }
            Spacer(minLength: 0)
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        await render(window)
        await render(window)

        XCTAssertEqual(footerTop - headerBottom, 300, accuracy: 0.5, "The rows around the response make room for its grown height")
        XCTAssertEqual(textTop, headerBottom, accuracy: 0.5, "The response starts below the header")
    }
}

/// What a settled reply's hosted content was last built from.
@MainActor
private final class HostedReplyProbe {
    var builds = 0
    var colorScheme: ColorScheme?
    var workspaceRoot: String?
    var openURL: OpenURLAction?
    var glyphHeight: CGFloat { leaf?.geometry?.glyphs.first?.rect.height ?? 0 }
    weak var leaf: ResponseSelectionLeafView?

    func recordBuild() { builds += 1 }
}

private struct HostedReplyProbeView: View {
    let probe: HostedReplyProbe
    let workspaceRoot: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        probe.colorScheme = colorScheme
        probe.workspaceRoot = workspaceRoot
        probe.openURL = openURL
        return Text("Reply").responseSelectableText("Reply")
    }
}

/// The chat around a settled reply: state the reply ignores, and the
/// workspace, appearance, text size and link handler it must follow.
@Observable
private final class HostedReplySurroundings {
    var unrelated = 0
    var workspaceRoot = "/first"
    var colorScheme = ColorScheme.light
    var dynamicTypeSize = DynamicTypeSize.large
    var linkHandler = "first"
    var opened: [String] = []
}

private struct HostedReplyParent: View {
    let surroundings: HostedReplySurroundings
    let probe: HostedReplyProbe

    var body: some View {
        let handler = surroundings.linkHandler
        let workspaceRoot = surroundings.workspaceRoot
        VStack {
            Text(verbatim: "\(surroundings.unrelated)")
            ResponseTextSelection(identity: "Reply", inputs: workspaceRoot) {
                let _ = probe.recordBuild()
                HostedReplyProbeView(probe: probe, workspaceRoot: workspaceRoot)
            }
        }
        .environment(\.colorScheme, surroundings.colorScheme)
        .environment(\.dynamicTypeSize, surroundings.dynamicTypeSize)
        .environment(\.openURL, OpenURLAction { [surroundings] _ in
            surroundings.opened.append(handler)
            return .handled
        })
    }
}

extension ResponseSelectionTests {
    private func showHostedReply() async throws -> (UIWindow, HostedReplySurroundings, HostedReplyProbe) {
        let surroundings = HostedReplySurroundings()
        let probe = HostedReplyProbe()
        let controller = UIHostingController(rootView: HostedReplyParent(surroundings: surroundings, probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        await render(window)
        await render(window)
        func leaf(in view: UIView) -> ResponseSelectionLeafView? {
            (view as? ResponseSelectionLeafView) ?? view.subviews.lazy.compactMap { leaf(in: $0) }.first
        }
        probe.leaf = try XCTUnwrap(leaf(in: controller.view))
        return (window, surroundings, probe)
    }

    func testSettledReplyRebuildsOnlyWhenItsInputsOrEnvironmentChange() async throws {
        let (window, surroundings, probe) = try await showHostedReply()
        defer { window.isHidden = true }
        let builds = probe.builds
        let height = probe.glyphHeight
        XCTAssertGreaterThan(height, 0)

        surroundings.unrelated += 1
        await render(window)
        XCTAssertEqual(probe.builds, builds, "An update the reply does not render from keeps its hosted content")

        surroundings.workspaceRoot = "/second"
        await render(window)
        XCTAssertEqual(probe.workspaceRoot, "/second", "The unchanged reply follows its new workspace")

        surroundings.colorScheme = .dark
        await render(window)
        XCTAssertEqual(probe.colorScheme, .dark, "The reply follows the new appearance")

        surroundings.dynamicTypeSize = .accessibility2
        await render(window)
        await render(window)
        XCTAssertGreaterThan(probe.glyphHeight, height * 1.5, "The reply's text follows the new text size")
    }

    func testSettledReplyLinksReachTheLatestHandler() async throws {
        let (window, surroundings, probe) = try await showHostedReply()
        defer { window.isHidden = true }

        surroundings.linkHandler = "second"
        await render(window)
        try XCTUnwrap(probe.openURL)(URL(string: "https://example.com")!)

        XCTAssertEqual(surroundings.opened, ["second"])
    }
}
