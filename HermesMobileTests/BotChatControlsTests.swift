import XCTest
@testable import HermesMobile

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

    func testMissingContextDoesNotUseCumulativeInputAsCurrentUsage() {
        let usage = BotChatUsage(.object(["input": .number(150_000), "context_max": .number(100_000)]))
        XCTAssertFalse(usage.hasContext)
        XCTAssertNil(usage.snapshot.lastPromptTokens)
        XCTAssertNil(usage.snapshot.outputTokens)
        XCTAssertNil(usage.snapshot.estimatedCost)
        XCTAssertFalse(BotChatUsage(.object(["context_used": .number(-1), "context_max": .number(100)])).hasContext)
        XCTAssertTrue(BotChatUsage(.object(["context_used": .number(0), "context_max": .number(100)])).hasContext)
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
        settings.snapshot(.object(["model": .string("model-b")]), idle: true)
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

    func testWorkspaceRequiresIdleAndOnlyChangesAfterAcknowledgment() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["cwd": .string("/old")]), idle: false)
        XCTAssertNil(settings.prepare(.workspace("/new")))
        settings.snapshot(.object(["cwd": .string("/old")]), idle: true)
        let action = try XCTUnwrap(settings.prepare(.workspace("/new")))
        wire.failure = BotSettingFailure.rejected(4017, "No such directory")
        await settings.apply(action)
        XCTAssertEqual(settings.workspace, "/old")
        wire.failure = nil; wire.response = .object(["cwd": .string("/new")])
        await settings.apply(try XCTUnwrap(settings.prepare(.workspace("/new"))))
        XCTAssertEqual(settings.workspace, "/new")
        XCTAssertEqual(wire.writes.last?.0, "session.cwd.set")
    }

    /// A method the host lacks is the connection's to remember: a second chat on it never
    /// sends the call, and a new connection starts with the control on.
    func testAMissingMethodStaysOffForEveryChatOnTheConnection() async throws {
        let wire = SettingsWire(), connection = UUID()
        let first = BotChatControls(), second = BotChatControls()
        await first.connect(context(connection), wire: wire)
        first.snapshot(.object([:]), idle: true)
        wire.failure = BotSettingFailure.rejected(-32601, "unknown method")
        await first.apply(try XCTUnwrap(first.prepare(.workspace("/new"))))
        XCTAssertFalse(first.mayChangeWorkspace)

        await second.connect(.init(connectionID: connection, profile: "same-profile", runtime: "second", generation: 1), wire: wire)
        second.snapshot(.object([:]), idle: true)
        XCTAssertFalse(second.mayChangeWorkspace)
        XCTAssertNil(second.prepare(.workspace("/new")))
        XCTAssertEqual(wire.writes.map(\.0), ["session.cwd.set"])

        let fresh = BotChatControls()
        await fresh.connect(context(), wire: SettingsWire())
        fresh.snapshot(.object([:]), idle: true)
        XCTAssertTrue(fresh.mayChangeWorkspace)
    }

    func testSessionControlsUseKnownStatesAndOfferReverseAction() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        wire.control = .object(["goal": .object(["title": .string("Finish"), "status": .string("active")]),
                               "loop": .object(["status": .string("future")])])
        await settings.connect(context(), wire: wire)
        let goal = try XCTUnwrap(settings.controls.first)
        XCTAssertEqual(goal.action, "goal.pause")
        XCTAssertNil(settings.controls.last?.action)
        wire.response = .object(["control": .object(["goal": .object(["title": .string("Finish"), "status": .string("paused")])])])
        await settings.apply(try XCTUnwrap(settings.prepare(.control(goal))))
        XCTAssertEqual(settings.controls.first?.action, "goal.resume")
        XCTAssertEqual(wire.writes.last?.1["action"], .string("goal.pause"))
        XCTAssertNil(settings.prepare(.control(goal)))
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

    func testLateControlReadCannotOverwriteAcknowledgedPause() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        wire.control = .object(["goal": .object(["status": .string("active")])])
        await settings.connect(context(), wire: wire)
        let goal = try XCTUnwrap(settings.controls.first)
        let readStarted = expectation(description: "Control read started")
        var finish: CheckedContinuation<Void, Never>?
        wire.afterControlRead = { await withCheckedContinuation { finish = $0; readStarted.fulfill() } }
        let reading = Task { await settings.reload() }
        await fulfillment(of: [readStarted], timeout: 3)
        wire.response = .object(["control": .object(["goal": .object(["status": .string("paused")])])])
        await settings.apply(try XCTUnwrap(settings.prepare(.control(goal))))
        finish?.resume(); await reading.value
        XCTAssertEqual(settings.controls.first?.status, "paused")
        XCTAssertFalse(settings.isLoading)
    }

    func testEffortAndFastUseExplicitSessionValuesAndWaitForAcknowledgment() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("medium"), "fast": .bool(true)]), idle: true)
        wire.failure = BotSettingFailure.rejected(4002, "Unsupported effort")
        await settings.apply(try XCTUnwrap(settings.prepare(.effort("high"))))
        XCTAssertEqual(settings.effort, "medium")
        XCTAssertEqual(settings.errorMessage, "Unsupported effort")
        wire.failure = nil
        wire.response = .object(["key": .string("reasoning"), "value": .string("none")])
        await settings.apply(try XCTUnwrap(settings.prepare(.effort("none"))))
        XCTAssertEqual(settings.effort, "none")
        wire.response = .object(["key": .string("fast"), "value": .string("normal")])
        await settings.apply(try XCTUnwrap(settings.prepare(.fast(false))))
        XCTAssertEqual(settings.fast, false)
        XCTAssertNotNil(settings.prepare(.fast(true)))
        wire.response = .object(["key": .string("fast"), "value": .string("fast")])
        await settings.apply(try XCTUnwrap(settings.prepare(.fast(true))))
        XCTAssertEqual(settings.fast, true)
        for (_, params) in wire.writes {
            XCTAssertEqual(params["scope"], .string("session"))
            XCTAssertEqual(params["session_id"], .string("runtime"))
            XCTAssertEqual(params["profile"], .string("same-profile"))
        }
        XCTAssertNil(settings.prepare(.effort("show")))
        XCTAssertNil(settings.prepare(.effort("off")))
    }

    func testEffortAndFastStaleActionsNeverWriteAfterReconnect() async throws {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("medium"), "fast": .bool(true)]), idle: true)
        let effort = try XCTUnwrap(settings.prepare(.effort("high")))
        let fast = try XCTUnwrap(settings.prepare(.fast(false)))
        await settings.connect(context(generation: 2), wire: wire)
        await settings.apply(effort); await settings.apply(fast)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testSnapshotSettingsNeverDispatchConfigWrites() async {
        let wire = SettingsWire(); let settings = BotChatControls()
        await settings.connect(context(), wire: wire)
        settings.snapshot(.object(["reasoning_effort": .string("ultra"), "fast": .bool(true)]), idle: true)
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
    var control: BotJSON = .object([:])
    var response = modelReply()
    var failure: Error?
    var beforeDispatch: (() -> Void)?
    var afterDispatch: (() async -> Void)?
    var afterControlRead: (() async -> Void)?
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
        if method == "session.control.read" {
            let result = BotJSON.object(["control": control])
            await afterControlRead?()
            return result
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
