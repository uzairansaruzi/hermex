import SwiftTerm
import SwiftUI
import UIKit

/// Full-screen terminal for one chat (presented from ChatView's toolbar button).
struct TerminalScreen: View {
    static let fontSizeKey = "terminal.fontSize"

    let workspace: String?
    let target: TerminalTarget
    let server: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: TerminalSessionController
    @State private var terminalHandle = TerminalHandle()

    init(workspace: String?, target: TerminalTarget, server: URL) {
        self.workspace = workspace
        self.target = target
        self.server = server
        _controller = State(initialValue: TerminalSessionController(target: target))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                if case let .failed(message) = controller.state {
                    ContentUnavailableView {
                        Label("Terminal unavailable", systemImage: "apple.terminal")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await controller.retry() } }
                    }
                } else {
                    SwiftTermView(controller: controller, handle: terminalHandle, openURL: { openURL($0) })
                        .padding(.horizontal, 8)   // text inset; the background still fills the edges
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .background(TerminalColors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Terminal").font(.headline)
                        if let workspace {
                            Text(workspace)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("terminal-title")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.keyboardShortcut("w", modifiers: .command)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await terminalHandle.restart(controller) }
                        } label: {
                            Label("Restart Shell", systemImage: "arrow.clockwise")
                        }
                        Button {
                            UIPasteboard.general.string = terminalHandle.allText()
                        } label: {
                            Label("Copy All Output", systemImage: "doc.on.doc")
                        }
                        Button {
                            if let text = UIPasteboard.general.string { controller.send(text) }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Label("Terminal Actions", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("terminal-menu")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.suspend()
            case .active: controller.resume()
            default: break
            }
        }
        .onDisappear { controller.dispose() }
        .onChange(of: controller.isRetired) { _, retired in
            if retired { dismiss() }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch controller.state {
        case .reconnecting:
            banner(text: String(localized: "Reconnecting…"), showsRestart: false, showsReconnect: false)
        case let .ended(reason):
            banner(text: endedText(reason), showsRestart: true, showsReconnect: reason.isDisconnected)
        default:
            EmptyView()
        }
    }

    private func endedText(_ reason: TerminalSessionController.EndReason) -> String {
        switch reason {
        case .exited:
            return String(localized: "Shell exited")
        case let .error(message):
            return message
        case let .disconnected(message):
            return message
        default:
            return String(localized: "Session ended")
        }
    }

    private func banner(text: String, showsRestart: Bool, showsReconnect: Bool) -> some View {
        HStack {
            Text(text)
                .font(.footnote.weight(.medium))
                .accessibilityIdentifier("terminal-status")
            Spacer()
            if showsReconnect {
                Button("Reconnect") { Task { await controller.reconnect() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("terminal-reconnect")
            }
            if showsRestart {
                Button("Restart") { Task { await terminalHandle.restart(controller) } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("terminal-restart")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Feeds raw PTY bytes in bounded slices, one per main run-loop pass. SwiftTerm
/// owns UTF-8/ANSI parsing across slices; bytes are never decoded per WebSocket frame.
@MainActor
final class TerminalOutputBatcher {
    static let defaultMaxPerPass = 16_384
    static let defaultMaxQueued = 262_144
    private let sink: (Data) -> Void
    private let maxPerPass: Int
    private let maxQueued: Int
    private var queue: [Data] = []
    private var head = 0
    private var scheduled = false

    init(maxPerPass: Int = TerminalOutputBatcher.defaultMaxPerPass,
         maxQueued: Int = TerminalOutputBatcher.defaultMaxQueued, sink: @escaping (Data) -> Void) {
        self.maxPerPass = max(1, maxPerPass)
        self.maxQueued = max(1, maxQueued)
        self.sink = sink
    }
    var hasPending: Bool { head < queue.count }
    private(set) var queuedBytes = 0
    private var roomWaiters: [CheckedContinuation<Void, Never>] = []

    /// Queues `bytes`, then returns only once fewer than `maxQueued` bytes wait for the
    /// screen. The socket reader awaits this before its next receive, so a flood stops
    /// being read while SwiftTerm is behind; no byte is dropped.
    func enqueue(_ bytes: Data) async {
        append(bytes)
        while queuedBytes >= maxQueued {
            await withCheckedContinuation { roomWaiters.append($0) }
        }
    }
    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.append(bytes)
        queuedBytes += bytes.count
        scheduleIfNeeded()
    }
    func append(_ text: String) { append(Data(text.utf8)) }
    func clear() {
        queue.removeAll(keepingCapacity: true); head = 0; queuedBytes = 0
        resumeWaitersIfRoom()
    }
    func flush() { while hasPending { drainOnePass() } }
    private func resumeWaitersIfRoom() {
        guard queuedBytes < maxQueued, !roomWaiters.isEmpty else { return }
        let waiters = roomWaiters
        roomWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    private func scheduleIfNeeded() {
        guard !scheduled, hasPending else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.drainOnePass()
            self.scheduleIfNeeded()
        }
    }
    func drainOnePass() {
        var slice = Data()
        while slice.count < maxPerPass, head < queue.count {
            let count = min(maxPerPass - slice.count, queue[head].count)
            slice.append(queue[head].prefix(count))
            queue[head].removeFirst(count)
            if queue[head].isEmpty { head += 1 }
        }
        queuedBytes -= slice.count
        if head == queue.count { queue.removeAll(keepingCapacity: true); head = 0 }
        else if head > 64 { queue.removeFirst(head); head = 0 }
        if !slice.isEmpty { sink(slice) }
        resumeWaitersIfRoom()
    }
}

enum TerminalLinks {
    /// Only web links open from the terminal (no file:, tel:, custom schemes).
    static func openableURL(_ link: String) -> URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum TerminalColors {
    /// The app's code-block colors (MarkdownRenderer's `codeBlockBackground`).
    static let background = Color(uiColor: backgroundUIColor)
    static let backgroundUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
            : UIColor.secondarySystemBackground
    }
    static let foregroundUIColor = UIColor.label
}

/// Lets the SwiftUI screen reach the UIKit terminal view (copy all, restart).
@MainActor
final class TerminalHandle {
    weak var view: SwiftTerm.TerminalView?

    func allText() -> String {
        guard let terminal = view?.getTerminal() else { return "" }
        let data = terminal.getBufferAsData(kind: .normal)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restart(_ controller: TerminalSessionController) async {
        await controller.restart()
    }

}

/// UIKit tells us when keyboard focus can actually be taken.
private final class TerminalInputView: SwiftTerm.TerminalView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { _ = becomeFirstResponder() }
    }
}

/// SwiftTerm's UIKit `TerminalView` wrapped for SwiftUI.
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalSessionController
    let handle: TerminalHandle
    let openURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, openURL: openURL)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let size = Coordinator.storedFontSize
        let view = TerminalInputView(frame: .zero, font: .monospacedSystemFont(ofSize: size, weight: .regular))
        view.terminalDelegate = context.coordinator
        Self.applyColors(to: view, scheme: context.environment.colorScheme)
        view.linkHighlightMode = .always
        view.changeScrollback(10_000)
        view.accessibilityIdentifier = "terminal-view"
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        // SwiftTerm's own tap only opens OSC 8 links in `.always` mode; also open plain
        // http(s) URLs printed by commands. Runs alongside SwiftTerm's tap (keyboard focus).
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        handle.view = view
        let batcher = TerminalOutputBatcher { [weak view] bytes in view?.feed(byteArray: [UInt8](bytes)[...]) }
        context.coordinator.batcher = batcher
        controller.onOutput = { bytes in await batcher.enqueue(bytes) }
        controller.onReset = { [weak view] in
            batcher.clear()
            view?.getTerminal().resetToInitialState()
            view?.setNeedsDisplay()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        let scheme = context.environment.colorScheme
        guard context.coordinator.appliedScheme != scheme else { return }
        context.coordinator.appliedScheme = scheme
        Self.applyColors(to: uiView, scheme: scheme)
    }

    /// SwiftTerm turns these into fixed terminal colors when set, so dynamic colors
    /// don't follow light/dark by themselves: resolve for the scheme and re-apply.
    private static func applyColors(to view: SwiftTerm.TerminalView, scheme: ColorScheme) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = TerminalColors.backgroundUIColor.resolvedColor(with: traits)
        view.nativeForegroundColor = TerminalColors.foregroundUIColor.resolvedColor(with: traits)
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.controller.onOutput = nil
        coordinator.controller.onReset = nil
        coordinator.batcher?.flush()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        static let minFontSize: CGFloat = 9
        static let maxFontSize: CGFloat = 20

        static var storedFontSize: CGFloat {
            let value = UserDefaults.standard.double(forKey: TerminalScreen.fontSizeKey)
            return value > 0 ? min(max(value, minFontSize), maxFontSize) : 12
        }

        let controller: TerminalSessionController
        let openURL: (URL) -> Void
        weak var view: SwiftTerm.TerminalView?
        var appliedScheme: ColorScheme?
        var batcher: TerminalOutputBatcher?
        private var pinchStartSize: CGFloat = 12
        private var didOpen = false

        init(controller: TerminalSessionController, openURL: @escaping (URL) -> Void) {
            self.controller = controller
            self.openURL = openURL
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pinchStartSize = view.font.pointSize
            case .changed, .ended:
                let size = (pinchStartSize * gesture.scale).rounded()
                let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
                if clamped != view.font.pointSize {
                    view.font = .monospacedSystemFont(ofSize: clamped, weight: .regular)
                }
                if gesture.state == .ended {
                    UserDefaults.standard.set(Double(clamped), forKey: TerminalScreen.fontSizeKey)
                }
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, gesture.state == .ended,
                  let cell = view.cellSizeInPixels(source: view.getTerminal()), cell.width > 0, cell.height > 0 else { return }
            // Same scale SwiftTerm uses for cellSizeInPixels (the window's, not the view's).
            let scale = view.window?.contentScaleFactor ?? UIScreen.main.scale
            // Viewport-relative point (the view scrolls), so rounding in the cell size can't drift far.
            let point = gesture.location(in: view)
            let viewportY = point.y - view.contentOffset.y
            let position = Position(col: Int(point.x * scale) / cell.width, row: Int(viewportY * scale) / cell.height)
            let terminal = view.getTerminal()
            guard position.col >= 0, position.col < terminal.cols, position.row >= 0, position.row < terminal.rows,
                  let link = terminal.link(at: .screen(position), mode: .explicitAndImplicit),
                  let url = TerminalLinks.openableURL(link) else { return }
            openURL(url)
        }

        // MARK: TerminalViewDelegate

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                // Measure first, then start: the first real size opens the shell.
                guard newCols > 1, newRows > 1 else { return }
                if !didOpen {
                    didOpen = true
                    Task { await controller.open(rows: newRows, cols: newCols) }

                } else {
                    controller.resize(rows: newRows, cols: newCols)
                }
            }
        }

        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { controller.send(Data(data)) }
        }

        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = TerminalLinks.openableURL(link) else { return }
            MainActor.assumeIsolated { openURL(url) }
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        nonisolated func bell(source: SwiftTerm.TerminalView) {}
        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                DispatchQueue.main.async { UIPasteboard.general.string = text }
            }
        }
        nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
