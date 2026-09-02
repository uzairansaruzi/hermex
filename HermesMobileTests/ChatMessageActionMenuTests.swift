import XCTest
@testable import HermesMobile

final class ChatMessageActionMenuTests: XCTestCase {
    func testAssistantMenuListsAssistantActionsInOrder() throws {
        let menu = try makeMenu(role: "assistant")

        XCTAssertEqual(menu.items.map(\.kind), [.listen, .selectText, .regenerate, .fork, .copy])
        XCTAssertTrue(menu.items.allSatisfy(\.isEnabled))
    }

    func testUserMenuListsUserActionsInOrder() throws {
        let menu = try makeMenu(role: "user")

        XCTAssertEqual(menu.items.map(\.kind), [.edit, .fork, .copy])
    }

    func testMutatingActionsDisableWhileStreaming() throws {
        let menu = try makeMenu(role: "assistant", hasActiveStream: true)

        let enabledByKind = Dictionary(uniqueKeysWithValues: menu.items.map { ($0.kind, $0.isEnabled) })
        XCTAssertEqual(enabledByKind[.regenerate], false)
        XCTAssertEqual(enabledByKind[.fork], false)
        XCTAssertEqual(enabledByKind[.listen], true)
        XCTAssertEqual(enabledByKind[.selectText], true)
        XCTAssertEqual(enabledByKind[.copy], true)

        let uiMenu = menu.uiMenu()
        let disabledTitles = uiMenu.children.compactMap { $0 as? UIAction }
            .filter { $0.attributes.contains(.disabled) }
            .map(\.title)
        XCTAssertEqual(disabledTitles, ["Regenerate Response", "Fork From Here"])
    }

    func testListenItemReflectsListeningState() throws {
        let idle = try makeMenu(role: "assistant")
        XCTAssertEqual(idle.items.first?.title, "Listen")

        let listening = try makeMenu(role: "assistant", listeningMessageID: "message-1")
        XCTAssertEqual(listening.items.first?.title, "Stop Listening")
    }

    func testPerformRoutesToTheMatchingCallback() throws {
        var copied: MessageActionContext?
        let menu = try makeMenu(role: "user", onCopy: { copied = $0 })

        let copy = try XCTUnwrap(menu.items.first { $0.kind == .copy })
        copy.perform()

        XCTAssertEqual(copied?.messageID, "message-1")
    }

    private func makeMenu(
        role: String,
        listeningMessageID: String? = nil,
        hasActiveStream: Bool = false,
        onCopy: @escaping (MessageActionContext) -> Void = { _ in }
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
            listeningMessageID: listeningMessageID,
            isViewingCachedData: false,
            hasActiveStream: hasActiveStream,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            onToggleListening: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: onCopy
        )
    }
}
