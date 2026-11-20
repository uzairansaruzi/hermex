import CoreGraphics
import Foundation
import SwiftUI

enum ChatScrollPolicy {
    static let initialTranscriptAnchor = UnitPoint.bottom

    static func sizeChangeAnchor(
        shouldFollowLatestMessage: Bool,
        isDisclosureSettling: Bool = false
    ) -> UnitPoint? {
        shouldFollowLatestMessage && !isDisclosureSettling ? .bottom : nil
    }

    static let bottomDetectionThreshold: CGFloat = 80

    static let streamingBottomDetectionThreshold: CGFloat = 160

    static let followReArmThreshold: CGFloat = 12

    static let dragSettleDelay: TimeInterval = 0.16

    static let momentumSettleDelay: TimeInterval = 0.05

    static let disclosureAnchorSuspension: TimeInterval = 0.25

    static let disclosureHoldQuietPeriod: TimeInterval = 0.3

    static let disclosureHoldMaximum: TimeInterval = 2

    enum FollowEvent: Equatable {
        case reset
        case userScrollBegin
        case userScrollEnd(isAtBottom: Bool)
        case contentScrolled(
            isAtBottom: Bool,
            isUserScrolling: Bool,
            movedAwayFromBottom: Bool = false,
            wasNearBottom: Bool = true
        )
    }

    struct ScrollGeometry: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var visibleHeight: CGFloat

        var distanceFromBottom: CGFloat {
            max(0, contentHeight - visibleHeight - offsetY)
        }
    }

    static func isScrollingAwayFromBottom(previous: ScrollGeometry?, current: ScrollGeometry) -> Bool {
        guard let previous, previous.visibleHeight == current.visibleHeight else { return false }
        let distance = current.distanceFromBottom
        return distance > previous.distanceFromBottom + 0.5
            && distance > streamingBottomDetectionThreshold
    }

    struct FollowLatch: Equatable {
        var isFollowing = true
        var ignoresCoastingGesture = false
    }

    static func streamingSendReArmsFollow(_ behavior: StreamingSendBehavior) -> Bool {
        behavior != .queue
    }

    static func resolveFollow(current: FollowLatch, event: FollowEvent) -> FollowLatch {
        var latch = current
        switch event {
        case .reset:
            latch.isFollowing = true
            latch.ignoresCoastingGesture = true
        case .userScrollBegin:
            latch.isFollowing = false
            latch.ignoresCoastingGesture = false
        case .userScrollEnd(let isAtBottom):
            latch.isFollowing = isAtBottom || current.isFollowing
            latch.ignoresCoastingGesture = false
        case .contentScrolled(let isAtBottom, let isUserScrolling, let movedAwayFromBottom, let wasNearBottom):
            if isUserScrolling {
                if !current.ignoresCoastingGesture {
                    latch.isFollowing = false
                }
            } else if movedAwayFromBottom {
                latch.isFollowing = false
            } else if isAtBottom, wasNearBottom {
                latch.isFollowing = true
            }
        }
        return latch
    }

    static func showsScrollToBottomButton(isNearBottom: Bool, isStreaming: Bool, isFollowing: Bool) -> Bool {
        !isNearBottom && (!isStreaming || !isFollowing)
    }

    static func isAtBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= followReArmThreshold
    }

    static func bottomThreshold(isStreaming: Bool) -> CGFloat {
        isStreaming ? streamingBottomDetectionThreshold : bottomDetectionThreshold
    }

    static func isNearBottom(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom <= bottomThreshold(isStreaming: isStreaming)
    }

    struct ReflowAnchor: Equatable {
        let id: String
        let fractionWithinRow: CGFloat
    }

    enum ReadingPlace: Equatable {
        case top
        case row(ReflowAnchor)

        func dependsOnFrame(of id: String) -> Bool {
            switch self {
            case .top: true
            case .row(let anchor): anchor.id == id
            }
        }
    }

    static func reflowAnchor(readingLineY: CGFloat, isAtTop: Bool, rowFrames: [String: CGRect]) -> ReflowAnchor? {
        guard !isAtTop else { return nil }
        let row = rowFrames
            .filter { $0.value.height > 0 && $0.value.minY <= readingLineY }
            .max { $0.value.minY < $1.value.minY }
        guard let row else { return nil }
        let fraction = (readingLineY - row.value.minY) / row.value.height
        return ReflowAnchor(id: row.key, fractionWithinRow: min(max(fraction, 0), 1))
    }

    static func reflowReadingLineY(anchor: ReflowAnchor, newFrame: CGRect) -> CGFloat {
        newFrame.minY + anchor.fractionWithinRow * newFrame.height
    }
}

final class ChatDisclosureToggleAction: Equatable {
    var handler: () -> Void = {}

    func callAsFunction() { handler() }

    static func == (lhs: ChatDisclosureToggleAction, rhs: ChatDisclosureToggleAction) -> Bool { lhs === rhs }
}

struct ChatDisclosureToggledKey: EnvironmentKey {
    static let defaultValue = ChatDisclosureToggleAction()
}

extension EnvironmentValues {
    var chatDisclosureToggled: ChatDisclosureToggleAction {
        get { self[ChatDisclosureToggledKey.self] }
        set { self[ChatDisclosureToggledKey.self] = newValue }
    }
}

final class TranscriptLinkRouter {
    enum Decision {
        case host(OpenURLAction.Result)
        case inAppBrowser
        case system
    }

    var handler: (URL) -> OpenURLAction.Result? = { _ in nil }
    var openInAppBrowser: (URL) -> Void = { url in
        MainActor.assumeIsolated { SafariView.present(url) }
    }

    private(set) lazy var openURL = OpenURLAction { [weak self] url in
        self?.route(url) ?? .systemAction
    }

    static func decision(for url: URL, hostResult: OpenURLAction.Result?) -> Decision {
        if let hostResult { return .host(hostResult) }
        return InAppBrowserPolicy.opensInApp(url) ? .inAppBrowser : .system
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        switch Self.decision(for: url, hostResult: handler(url)) {
        case .host(let result):
            return result
        case .inAppBrowser:
            openInAppBrowser(url)
            return .handled
        case .system:
            return .systemAction
        }
    }
}

extension View {
    func chatDisclosureToggled(perform handler: @escaping () -> Void) -> some View {
        modifier(ChatDisclosureToggledModifier(handler: handler))
    }

    func transcriptLinks(perform handler: @escaping (URL) -> OpenURLAction.Result?) -> some View {
        modifier(TranscriptLinksModifier())
            .modifier(TranscriptLinkHandlerModifier(handler: handler))
    }

    func transcriptLinks() -> some View {
        transcriptLinks { _ in nil }
    }
}

private struct ChatDisclosureToggledModifier: ViewModifier {
    let handler: () -> Void
    @State private var action = ChatDisclosureToggleAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content.environment(\.chatDisclosureToggled, action)
    }
}

private struct TranscriptLinkHandlerModifier: ViewModifier {
    let handler: (URL) -> OpenURLAction.Result?
    @State private var router = TranscriptLinkRouter()

    func body(content: Content) -> some View {
        router.handler = handler
        return content.environment(\.transcriptLinkRouter, router)
    }
}

private struct TranscriptLinksModifier: ViewModifier {
    @Environment(\.transcriptLinkRouter) private var router

    func body(content: Content) -> some View {
        content.environment(\.openURL, router?.openURL ?? OpenURLAction { _ in .systemAction })
    }
}

private struct TranscriptLinkRouterKey: EnvironmentKey {
    static let defaultValue: TranscriptLinkRouter? = nil
}

private extension EnvironmentValues {
    var transcriptLinkRouter: TranscriptLinkRouter? {
        get { self[TranscriptLinkRouterKey.self] }
        set { self[TranscriptLinkRouterKey.self] = newValue }
    }
}

struct ChatCompletionScrollPolicy {
    static func finalResponseRenderID(
        in messages: [TranscriptMessage], terminalReplyRenderIDs: Set<String>
    ) -> String? {
        let lastUserIndex = messages.last(where: {
            $0.message.role == "user" && !$0.message.isSteerMessage
        })?.loadedIndex ?? -1
        return messages.last(where: {
            $0.loadedIndex > lastUserIndex && $0.message.role == "assistant"
                && terminalReplyRenderIDs.contains($0.renderID)
        })?.renderID
    }

    private var streamID: String?
    private var readerTookOwnership = false
    private var consumed = false

    mutating func begin(streamID: String, isFollowing: Bool) {
        guard self.streamID != streamID else { return }
        self.streamID = streamID
        readerTookOwnership = !isFollowing
        consumed = false
    }

    mutating func observe(_ event: ChatScrollPolicy.FollowEvent) {
        switch event {
        case .userScrollBegin:
            readerTookOwnership = true
        case .contentScrolled(_, let isUserScrolling, let movedAway, _):
            if isUserScrolling || movedAway { readerTookOwnership = true }
        default:
            break
        }
    }

    mutating func readerDidInteract() { readerTookOwnership = true }

    mutating func consumeCompletion(streamID: String, enabled: Bool, sceneIsActive: Bool = true) -> Bool {
        guard sceneIsActive, self.streamID == streamID, !consumed else { return false }
        consumed = true
        return enabled && !readerTookOwnership
    }
}
