import XCTest
@testable import HermesMobile

@MainActor final class BotProfileEditorTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!

    func testMissingAndUnknownDescribeFieldsDecodeTolerantly() {
        let details = BotProfileDetails(.object(["name": .string("same"), "future": .object(["new": .bool(true)])]),
                                        expectedName: "same")
        XCTAssertEqual(details.name, "same")
        XCTAssertEqual(details.description, "")
        XCTAssertEqual(details.instructions, "")
        XCTAssertNil(details.model)
        XCTAssertEqual(details.skills, [])
        XCTAssertEqual(details.toolsets, [])
        XCTAssertEqual(details.mcpServers, [])
    }

    func testPartialApplyAdvancesOnlySuccessfulSectionsAndKeepsFailuresDirty() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setDescription("New role")
        editor.setInstructions("New instructions")
        editor.setEnabled(false, field: .skills, id: "research")
        wire.configure = { _ in
            .object(["ok": .bool(false), "applied": .object([
                "description": .bool(false), "soul": .bool(true), "skills": .bool(true)
            ])])
        }

        await editor.save()

        XCTAssertEqual(editor.dirtyFields, [.description])
        XCTAssertEqual(editor.outcomes[.description], .failed("Failed"))
        XCTAssertEqual(editor.outcomes[.instructions], .saved)
        XCTAssertEqual(editor.outcomes[.skills], .saved)
        let params = try XCTUnwrap(wire.calls.last(where: { $0.0 == "profiles.configure" })?.1)
        XCTAssertEqual(params["description"], .string("New role"))
        XCTAssertEqual(params["soul"], .string("New instructions"))
        XCTAssertEqual(params["disabled_skills"], .array([.string("research")]))
    }

    func testDeclinedModelConfirmationLeavesTheSelectionDirty() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setModel(ModelCatalogOption(id: "guarded", displayName: "guarded", providerID: "provider"))
        wire.configure = { _ in
            .object(["ok": .bool(true), "applied": .object([:]), "confirm_required": .bool(true),
                     "confirm_message": .string("This model may cost more.")])
        }

        await editor.save()
        XCTAssertEqual(editor.confirmation?.message, "This model may cost more.")
        XCTAssertEqual(editor.outcomes[.model], .confirmationRequired)
        editor.declineModelChange()

        XCTAssertNil(editor.confirmation)
        XCTAssertTrue(editor.dirtyFields.contains(.model))
        guard case .failed(let message) = editor.outcomes[.model] else { return XCTFail("expected a retained model failure") }
        XCTAssertTrue(message.contains("declined"))
    }

    func testConfirmedModelResendsOnlyTheModelSection() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setModel(ModelCatalogOption(id: "guarded", displayName: "guarded", providerID: "provider"))
        var configureCount = 0
        wire.configure = { params in
            configureCount += 1
            if configureCount == 1 {
                return .object(["ok": .bool(true), "applied": .object([:]), "confirm_required": .bool(true),
                                "confirm_message": .string("Confirm")])
            }
            XCTAssertEqual(params["confirm_expensive_model"], .bool(true))
            XCTAssertEqual(Set(params.keys), ["name", "model", "provider", "confirm_expensive_model"])
            return .object(["ok": .bool(true), "applied": .object(["model": .bool(true)])])
        }

        await editor.save()
        await editor.confirmModelChange()

        XCTAssertFalse(editor.dirtyFields.contains(.model))
        XCTAssertEqual(editor.outcomes[.model], .saved)
        XCTAssertEqual(configureCount, 2)
    }

    func testAppearanceConflictPreservesDesktopFieldsAndLocalDirtyEdits() async throws {
        let look: [String: BotJSON] = [
            "title": .string("Researcher"), "sectionId": .string("desktop-section"),
            "groups": .array([.string("ops")]), "created": .number(12),
            "description": .string("Desktop-owned summary")
        ]
        let profile = self.profile(look: look, revision: 4)
        let (editor, wire, _) = try makeEditor(profile: profile, details: details())
        await editor.load()
        editor.setTitle("New title")
        wire.configure = { params in
            let sent = params["ui_meta"]?["hermes-bots"].fields
            XCTAssertEqual(sent?["sectionId"], .string("desktop-section"))
            XCTAssertEqual(sent?["groups"], .array([.string("ops")]))
            XCTAssertEqual(sent?["created"], .number(12))
            XCTAssertEqual(sent?["description"], .string("Desktop-owned summary"))
            XCTAssertEqual(params["ui_meta_expected_revisions"], .object(["hermes-bots": .number(4)]))
            return .object(["ok": .bool(false), "applied": .object([
                "ui_meta": .bool(false),
                "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": .number(4), "actual": .number(5)])])
            ])])
        }

        await editor.save()

        XCTAssertEqual(editor.outcomes[.appearance], .conflict)
        XCTAssertTrue(editor.dirtyFields.contains(.appearance))
        XCTAssertEqual(editor.draft.appearance.title, "New title")
    }

    func testReloadingAConflictUpdatesOnlyAppearanceAndKeepsOtherDirtySections() async throws {
        let initial = profile(look: ["title": .string("Researcher"), "sectionId": .string("one")], revision: 4)
        let (editor, wire, _) = try makeEditor(profile: initial, details: details())
        await editor.load()
        editor.setTitle("Phone title")
        editor.setInstructions("Phone instructions")
        wire.configure = { _ in
            .object(["ok": .bool(false), "applied": .object([
                "ui_meta": .bool(false),
                "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": .number(4), "actual": .number(5)])]),
                "soul": .bool(false)
            ])])
        }
        await editor.save()
        wire.roster = .object(["profiles": .array([.object([
            "name": .string("same"),
            "ui_meta": .object(["hermes-bots": .object([
                "title": .string("Desktop title"), "sectionId": .string("two")
            ])]),
            "ui_meta_revisions": .object(["hermes-bots": .number(5)])
        ])])])

        await editor.reloadAppearance()

        XCTAssertEqual(editor.draft.appearance.title, "Desktop title")
        XCTAssertEqual(editor.draft.instructions, "Phone instructions")
        XCTAssertEqual(editor.dirtyFields, [.instructions])
        XCTAssertNil(editor.outcomes[.appearance])
    }

    func testAvatarWriteRunsOnlyAfterAppearanceRevisionApplies() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.removeAvatar()
        wire.configure = { _ in
            .object(["ok": .bool(true), "applied": .object([
                "ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)])
            ])])
        }

        await editor.save()

        XCTAssertEqual(wire.calls.filter { $0.0 == "profiles.configure" }.count, 1)
        let asset = try XCTUnwrap(wire.calls.last(where: { $0.0 == "profiles.set_asset" })?.1)
        XCTAssertEqual(asset["asset"], .string("avatar"))
        XCTAssertEqual(asset["clear"], .bool(true))
        XCTAssertFalse(editor.dirtyFields.contains(.avatar))
    }

    func testConnectionSwitchDuringSaveCannotApplyTheOldConnectionsReply() async throws {
        let currentConnection = connection(name: "One")
        let other = connection(name: "Two")
        let keychain = InMemoryKeychainStore()
        var store = BotConnectionStore(keychain: keychain)
        try store.save(currentConnection, server: server)
        let wire = BotProfileEditorWire(details: details())
        let editor = BotProfileEditor(server: server, connection: currentConnection, profile: profile(), avatar: nil,
                                      store: store, avatarStore: BotAvatarStore(), makeWire: { _ in wire })
        await editor.load()
        editor.setInstructions("Changed")
        wire.configure = { _ in
            try store.save(other, server: self.server)
            return .object(["ok": .bool(true), "applied": .object(["soul": .bool(true)])])
        }

        await editor.save()

        XCTAssertTrue(editor.dirtyFields.contains(.instructions))
        guard case .failed? = editor.outcomes[.instructions] else { return XCTFail("the switched connection must fail visibly") }
    }

    func testLateSaveCallbackAfterCloseCannotMutateEditorState() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setInstructions("Changed")
        wire.configure = { [weak editor] _ in
            editor?.close()
            return .object(["ok": .bool(true), "applied": .object(["soul": .bool(true)])])
        }

        await editor.save()

        XCTAssertTrue(editor.dirtyFields.contains(.instructions))
        XCTAssertTrue(editor.outcomes.isEmpty)
        XCTAssertFalse(editor.isSaving)
    }

    func testBackgroundingAnInFlightSavePreservesDraftAndMarksOutcomeUncertain() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setInstructions("Changed")
        wire.configure = { [weak editor] _ in
            editor?.suspend()
            return .object(["ok": .bool(true), "applied": .object(["soul": .bool(true)])])
        }

        await editor.save()

        XCTAssertTrue(editor.dirtyFields.contains(.instructions))
        XCTAssertEqual(editor.outcomes[.instructions], .failed("Outcome Uncertain"))
        XCTAssertFalse(editor.isSaving)
    }

    func testEqualProfileNamesOnTwoConnectionsLoadTheirOwnScopedDetails() async throws {
        let serverTwo = URL(string: "https://two.example")!
        let one = connection(name: "One")
        let two = connection(name: "Two")
        let keychain = InMemoryKeychainStore()
        let store = BotConnectionStore(keychain: keychain)
        try store.save(one, server: server)
        try store.save(two, server: serverTwo)
        let wireOne = BotProfileEditorWire(details: details(description: "First host"))
        let wireTwo = BotProfileEditorWire(details: details(description: "Second host"))
        let first = BotProfileEditor(server: server, connection: one, profile: profile(), avatar: nil,
                                     store: store, avatarStore: BotAvatarStore(), makeWire: { _ in wireOne })
        let second = BotProfileEditor(server: serverTwo, connection: two, profile: profile(), avatar: nil,
                                      store: store, avatarStore: BotAvatarStore(), makeWire: { _ in wireTwo })

        await first.load(); await second.load()

        XCTAssertEqual(first.draft.description, "First host")
        XCTAssertEqual(second.draft.description, "Second host")
        XCTAssertNotEqual(first.connection.id, second.connection.id)
    }

    func testReloadingAConflictRefetchesOnlyThisBotsAvatar() async throws {
        let avatars = BotAvatarStore()
        let connection = connection(name: "Mac")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let other = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        avatars.setImage(other, connectionID: connection.id, profile: "other", revision: 1)
        let wire = BotProfileEditorWire(details: details())
        wire.roster = .object(["profiles": .array([
            .object(["name": .string("same"), "ui_meta_revisions": .object(["hermes-bots": .number(5)])])
        ])])
        let editor = BotProfileEditor(server: server, connection: connection, profile: profile(revision: 4), avatar: nil,
                                      store: store, avatarStore: avatars, makeWire: { _ in wire })
        await editor.load()

        await editor.reloadAppearance()

        XCTAssertNotNil(avatars.images(connectionID: connection.id)["other"], "another bot's image must survive a one-bot reload")
        XCTAssertFalse(wire.calls.contains { $0.0 == "profiles.get_asset" }, "a row without an avatar fetches nothing")
        XCTAssertNil(editor.avatar)
    }

    func testReloadAfterASaveKeepsTheSavedAppearance() async throws {
        let (editor, wire, _) = try makeEditor(details: details())
        await editor.load()
        editor.setTitle("Renamed")
        editor.setShape(.hexagon)
        wire.configure = { _ in
            .object(["ok": .bool(true), "applied": .object([
                "ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(2)])
            ])])
        }
        await editor.save()

        await editor.load()

        XCTAssertEqual(editor.draft.appearance.title, "Renamed")
        XCTAssertEqual(editor.draft.appearance.shape, "hexagon")
        XCTAssertTrue(editor.dirtyFields.isEmpty)
    }

    func testStoredAvatarIsBoundedToTheStoresThumbnailSize() {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { _ in }
        let thumbnail = try? XCTUnwrap(BotAvatarStore.thumbnail(large))
        XCTAssertEqual(thumbnail.map { max($0.size.width * $0.scale, $0.size.height * $0.scale) }, CGFloat(BotAvatarStore.maxPixelSize))
        let small = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }
        XCTAssertEqual(BotAvatarStore.thumbnail(small)?.size, small.size)
    }

    private func makeEditor(profile: BotProfile? = nil, details: BotJSON) throws -> (BotProfileEditor, BotProfileEditorWire, BotConnectionStore) {
        let connection = connection(name: "Mac")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let wire = BotProfileEditorWire(details: details)
        let editor = BotProfileEditor(server: server, connection: connection, profile: profile ?? self.profile(), avatar: nil,
                                      store: store, avatarStore: BotAvatarStore(), makeWire: { _ in wire })
        return (editor, wire, store)
    }

    private func connection(name: String) -> BotConnection {
        BotConnection(id: UUID(), name: name, address: URL(string: "https://\(name.lowercased()).example")!,
                      username: "u", password: "p", hermesVersion: nil)
    }

    private func profile(look: [String: BotJSON] = [:], revision: Int? = nil) -> BotProfile {
        var row: [String: BotJSON] = ["name": .string("same")]
        if !look.isEmpty { row["ui_meta"] = .object(["hermes-bots": .object(look)]) }
        if let revision { row["ui_meta_revisions"] = .object(["hermes-bots": .number(Double(revision))]) }
        return BotProfile(.object(row))!
    }

    private func details(description: String = "Find sources") -> BotJSON {
        .object([
            "name": .string("same"), "description": .string(description), "soul": .string("Be careful"),
            "model": .object(["provider": .string("provider"), "default": .string("model-a")]),
            "skills": .array([.object(["name": .string("research"), "enabled": .bool(true)])]),
            "toolsets": .array([.object(["name": .string("web"), "label": .string("Web"),
                                         "description": .string("Search the web"), "tool_count": .number(4), "enabled": .bool(true)])]),
            "toolsets_pinned": .bool(false),
            "mcp_servers": .array([.object(["name": .string("linear"), "transport": .string("http"), "enabled": .bool(true)])]),
            "future": .array([.number(1)])
        ])
    }
}

@MainActor private final class BotProfileEditorWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var details: BotJSON
    var roster: BotJSON = .object(["profiles": .array([])])
    var configure: (([String: BotJSON]) throws -> BotJSON)?
    var calls: [(String, [String: BotJSON])] = []

    init(details: BotJSON) { self.details = details }
    func connect() async throws {}
    func close() {}
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append((method, params))
        switch method {
        case "profiles.describe": return details
        case "profiles.list": return roster
        case "model.options":
            return .object(["model": .string("model-a"), "provider": .string("provider"), "providers": .array([
                .object(["slug": .string("provider"), "name": .string("Provider"),
                         "models": .array([.string("model-a"), .string("guarded")])])
            ])])
        case "profiles.configure":
            guard let configure else { throw BotFailure.unsupported }
            return try configure(params)
        case "profiles.set_asset":
            return .object(["ok": .bool(true), "asset": .string("avatar"), "size": .number(0)])
        default: throw BotFailure.unsupported
        }
    }
}
