import XCTest
@testable import HermesMobile

/// A Hermes chat's model, effort and Fast controls (`HermesChatSettings` owns one).
@MainActor final class BotChatControlsTests: XCTestCase {
    private func context(_ id: UUID = UUID(), generation: Int = 1) -> BotChatControls.Context {
        .init(connectionID: id, profile: "same-profile", runtime: "runtime", generation: generation)
    }
    private let next = ModelCatalogOption(id: "model-b", displayName: "model-b", providerID: "provider")

    func testCatalogToleratesUnknownFieldsAndDeduplicatesRows() {
        let catalog = HermesModelCatalog(SettingsWire.catalog)
        XCTAssertEqual(catalog.groups.count, 1)
        XCTAssertEqual(catalog.groups[0].models.count, 2)
        XCTAssertEqual(catalog.active?.id, "model-a")
        XCTAssertTrue(HermesModelCatalog(.object([:])).groups.isEmpty)
    }

    func testModelWireValueAlwaysPinsSessionAndRejectsFlags() {
        XCTAssertEqual(HermesModelCatalog.sessionModelValue(next), "model-b --provider provider --session")
        for id in ["m --global", "m\n--once", "—global", "--global"] {
            XCTAssertNil(HermesModelCatalog.sessionModelValue(.init(id: id, displayName: id, providerID: "provider")))
        }
    }

    func testModelConfirmationCanBeRejectedWithoutChangingSelectionOrDefaults() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        wire.response = SettingsWire.modelReply(confirm: true)
        await settings.apply(try XCTUnwrap(settings.prepare(.model(next))))
        XCTAssertEqual(settings.confirmation?.message, "This model costs more.")
        XCTAssertEqual(settings.catalog.active?.id, "model-a")
        settings.cancelConfirmation()
        XCTAssertNil(settings.confirmation)
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertEqual(wire.writes[0].1["scope"], .string("session"))
        XCTAssertEqual(wire.writes[0].1["confirm_expensive_model"], .bool(false))
        XCTAssertEqual(wire.writes[0].1["profile"], .string("same-profile"))
        XCTAssertEqual(wire.writes[0].1["session_id"], .string("runtime"))
    }

    func testConfirmedDeferredChoiceDoesNotBecomeActiveUntilLiveCatalogChanges() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        wire.response = SettingsWire.modelReply(confirm: true)
        await settings.apply(try XCTUnwrap(settings.prepare(.model(next))))
        wire.response = SettingsWire.modelReply(deferred: true)
        await settings.confirm()
        XCTAssertEqual(wire.writes.last?.1["confirm_expensive_model"], .bool(true))
        XCTAssertEqual(settings.pendingModel, next)
        XCTAssertEqual(settings.catalog.active?.id, "model-a")
        settings.snapshot(.object(["model": .string("model-b")]))
        XCTAssertEqual(settings.catalog.active?.id, "model-a")
        wire.active = "model-b"
        await settings.reload()
        XCTAssertNil(settings.pendingModel)
        XCTAssertEqual(settings.catalog.active?.id, "model-b")
    }

    func testRejectedAndUnsupportedWritesPreserveSelectionAndHostError() async throws {
        for code in [4002, -32601, 403] {
            let wire = SettingsWire(); let settings = BotChatControls()
            await settings.connect(context(), wire: wire)
            wire.failure = BotSettingFailure.rejected(code, "Host refused this choice")
            await settings.apply(try XCTUnwrap(settings.prepare(.model(next))))
            XCTAssertEqual(settings.catalog.active?.id, "model-a")
            XCTAssertEqual(settings.errorMessage, "Host refused this choice")
            XCTAssertEqual(settings.mayChangeModel, code == 4002)
        }
    }

    func testUnknownReplyIsNotSuccessAndIsNeverAutomaticallyRetried() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        let action = try XCTUnwrap(settings.prepare(.model(next)))
        wire.response = .object(["future": .bool(true)])
        await settings.apply(action)
        await settings.apply(action)
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertEqual(settings.catalog.active?.id, "model-a")
        XCTAssertNotNil(settings.errorMessage)
    }

    func testDisconnectBeforeDispatchMakesOldActionInert() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        let action = try XCTUnwrap(settings.prepare(.model(next)))
        wire.beforeDispatch = { settings.disconnect() }
        await settings.apply(action)
        XCTAssertTrue(wire.writes.isEmpty)
        XCTAssertNil(settings.confirmation)
    }

    func testStaleApplyAfterReconnectCannotTouchNewConnectionWithSameProfile() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        let sent = expectation(description: "model request sent")
        var finish: CheckedContinuation<Void, Never>?
        wire.afterDispatch = { await withCheckedContinuation { finish = $0; sent.fulfill() } }
        wire.response = SettingsWire.modelReply(confirm: true)
        let action = try XCTUnwrap(settings.prepare(.model(next)))
        let pending = Task { await settings.apply(action) }
        await fulfillment(of: [sent], timeout: 3)
        let other = SettingsWire(); other.active = "other-model"
        await settings.connect(context(generation: 2), wire: other)
        finish?.resume(); await pending.value
        XCTAssertEqual(settings.catalog.active?.id, "other-model")
        XCTAssertNil(settings.confirmation)
        XCTAssertFalse(settings.isApplying)
        XCTAssertTrue(other.writes.isEmpty)
    }

    /// A method the host lacks is the connection's to remember: a second chat on it never
    /// sends the call, and a new connection starts with the control on.
    func testAMissingMethodStaysOffForEveryChatOnTheConnection() async throws {
        let wire = SettingsWire(), connection = UUID()
        let first = BotChatControls(), second = BotChatControls()
        await first.connect(context(connection), wire: wire)
        wire.failure = BotSettingFailure.rejected(-32601, "unknown method")
        await first.apply(try XCTUnwrap(first.prepare(.model(next))))
        XCTAssertFalse(first.mayChangeModel)

        await second.connect(.init(connectionID: connection, profile: "same-profile", runtime: "second", generation: 1), wire: wire)
        XCTAssertFalse(second.mayChangeModel)
        XCTAssertNil(second.prepare(.model(next)))
        XCTAssertEqual(wire.writes.map(\.0), ["config.set"])

        let fresh = BotChatControls()
        await fresh.connect(context(), wire: SettingsWire())
        XCTAssertTrue(fresh.mayChangeModel)
    }

    func testConfirmationCannotOverwriteADesktopModelChange() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        wire.response = SettingsWire.modelReply(confirm: true)
        await settings.apply(try XCTUnwrap(settings.prepare(.model(next))))
        wire.active = "desktop-choice"
        await settings.reload()
        await settings.confirm()
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertEqual(settings.catalog.active?.id, "desktop-choice")
        XCTAssertNotNil(settings.errorMessage)
    }

    func testEffortUsesExplicitSessionValuesAndWaitsForAcknowledgment() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("medium")]))
        wire.failure = BotSettingFailure.rejected(4002, "Unsupported effort")
        await settings.apply(try XCTUnwrap(settings.prepare(.effort("high"))))
        XCTAssertEqual(settings.effort, "medium")
        XCTAssertEqual(settings.errorMessage, "Unsupported effort")
        wire.failure = nil
        wire.response = .object(["key": .string("reasoning"), "value": .string("none")])
        await settings.apply(try XCTUnwrap(settings.prepare(.effort("none"))))
        XCTAssertEqual(settings.effort, "none")
        for (_, params) in wire.writes {
            XCTAssertEqual(params["scope"], .string("session"))
            XCTAssertEqual(params["session_id"], .string("runtime"))
            XCTAssertEqual(params["profile"], .string("same-profile"))
        }
        XCTAssertNil(settings.prepare(.effort("show")))
        XCTAssertNil(settings.prepare(.effort("off")))
    }

    func testStaleEffortActionNeverWritesAfterReconnect() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("medium")]))
        let effort = try XCTUnwrap(settings.prepare(.effort("high")))
        await settings.connect(context(generation: 2), wire: wire)
        await settings.apply(effort)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testSnapshotSettingsNeverDispatchConfigWrites() async {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("ultra"), "fast": .bool(true)]))
        XCTAssertEqual(settings.effort, "ultra")
        XCTAssertEqual(settings.fast, true)
        XCTAssertTrue(wire.writes.isEmpty)
    }
}

@MainActor private final class SettingsWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var active = "model-a"
    var response = modelReply()
    var failure: Error?
    var beforeDispatch: (() -> Void)?
    var afterDispatch: (() async -> Void)?
    var writes: [(String, [String: BotJSON])] = []
    /// The connection's missing methods: like the gateway, a -32601 adds its method.
    var unavailableMethods: Set<String> = []
    func connect() async throws {}
    func close() {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let method = call.method, params = try call.params()
        if method == "model.options" {
            var fields = Self.catalog.fields!; fields["model"] = .string(active)
            return .object(fields)
        }
        beforeDispatch?(); try validateDispatch?()
        writes.append((method, params))
        await afterDispatch?()
        if case BotSettingFailure.rejected(-32601, _)? = failure { unavailableMethods.insert(method) }
        if let failure { throw failure }
        return response
    }
    static var catalog: BotJSON {
        .object(["model": .string("model-a"), "provider": .string("provider"), "providers": .array([
            .object(["slug": .string("provider"), "name": .string("Provider"), "models": .array([.string("model-a"), .string("model-b"), .string("model-b"), .null]), "future": .bool(true)]),
            .object(["slug": .string("provider")]), .null
        ])])
    }
    static func modelReply(confirm: Bool = false, deferred: Bool = false) -> BotJSON {
        .object(["key": .string("model"), "value": .string("model-b"), "scope": .string("session"),
                 "confirm_required": .bool(confirm), "confirm_message": .string("This model costs more."), "deferred": .bool(deferred)])
    }
}
