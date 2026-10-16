import XCTest
@testable import HermesMobile

final class ChatMessageActionMenuTests: XCTestCase {
    func testMutatingActionsDisableWhileStreaming() throws {
        let menu = try makeMenu(role: "assistant", hasActiveStream: true)

        let enabledByKind = Dictionary(uniqueKeysWithValues: menu.items.map { ($0.kind, $0.isEnabled) })
        XCTAssertEqual(enabledByKind[.regenerate], false)
        XCTAssertEqual(enabledByKind[.fork], false)
        XCTAssertEqual(enabledByKind[.listen], true)

        let disabled = menu.uiMenu().children.compactMap { $0 as? UIAction }
            .filter { $0.attributes.contains(.disabled) }
        XCTAssertEqual(disabled.map(\.title), menu.items.filter { !$0.isEnabled }.map(\.title),
                       "The menu UIKit shows disables the same two actions")
    }

    func testCachedResponseRetainsListenButDisablesServerMutations() throws {
        let menu = try makeMenu(role: "assistant", isViewingCachedData: true)
        XCTAssertEqual(menu.items.filter(\.isEnabled).map(\.kind), [.listen])
    }

    func testPendingResponseMutationsAreDisabled() throws {
        let menu = try makeMenu(role: "assistant", isMutating: true)
        XCTAssertEqual(menu.items.filter(\.isEnabled).map(\.kind), [.listen])
    }

    private func makeMenu(
        role: String,
        hasActiveStream: Bool = false,
        isViewingCachedData: Bool = false,
        isMutating: Bool = false
    ) throws -> ChatMessageActionMenu {
        let message = ChatMessage(
            role: role,
            content: "Hello there",
            timestamp: 1_770_000_000,
            messageId: "message-1"
        )
        let context = try XCTUnwrap(
            MessageActionContext(message: message, visibleIndex: 0, messagesOffset: 0)
        )
        return ChatMessageActionMenu(
            context: context,
            listeningMessageID: nil,
            isViewingCachedData: isViewingCachedData,
            hasActiveStream: hasActiveStream,
            isRegeneratingMessage: isMutating,
            isEditingMessage: false,
            isForkingMessage: isMutating,
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }
        )
    }
}
