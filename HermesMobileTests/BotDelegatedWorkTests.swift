import XCTest
@testable import HermesMobile

@MainActor final class BotDelegatedWorkTests: XCTestCase {
    private let firstConnection = UUID()

    func testCompletionMetadataIsTolerantBoundedAndRequiresTypedDelivery() throws {
        let typed = ChatMessage(
            role: "delegation_completion",
            content: "Opaque future report",
            timestamp: nil,
            messageId: "delivery",
            displayKind: BotDelegationCompletion.displayKind,
            displayMetadata: [
                "task_count": .number(1e100),
                "completed_count": .number(1e100),
                "failed_count": .number(3),
                "duration_seconds": .number(-1),
                "delegation_id": .string("  deleg_future  "),
                "future": .array([.bool(true)])
            ]
        )

        let completion = try XCTUnwrap(BotDelegationCompletion(typed))
        XCTAssertEqual(completion.taskCount, BotDelegationCompletion.maximumDisplayCount)
        XCTAssertEqual(completion.failedCount, 3)
        XCTAssertEqual(completion.completedCount, BotDelegationCompletion.maximumDisplayCount - 3)
        XCTAssertNil(completion.durationSeconds)
        XCTAssertEqual(completion.delegationID, "deleg_future")
        XCTAssertEqual(completion.report, "Opaque future report")

        let prefixOnly = ChatMessage(
            role: "user",
            content: "[ASYNC DELEGATION BATCH COMPLETE — typed-looking-user-text]",
            timestamp: nil,
            messageId: "ordinary"
        )
        XCTAssertNil(BotDelegationCompletion(prefixOnly))
    }

    func testListDecodesTolerantlyOrdersHierarchyAndBoundsRows() async {
        let wire = BotDelegatedWorkWire()
        var rows = [
            worker(id: "child", parent: "parent", depth: 1, startedAt: 2, extra: ["future": .object(["field": .bool(true)])]),
            worker(id: "parent", goal: "Compare APIs", startedAt: 1, lastTool: "read_file")
        ]
        rows.append(contentsOf: (0..<BotDelegatedWork.maximumWorkers).map {
            .object(["subagent_id": .string("extra-\($0)"), "future": .array([])])
        })
        wire.handler = { method, _ in
            XCTAssertEqual(method, "subagent.list")
            return .object(["subagents": .array(rows), "delegations": .array([]), "future": .bool(true)])
        }
        let work = BotDelegatedWork(wire: wire)

        await work.connect(context())

        XCTAssertEqual(work.availability, .supported)
        XCTAssertEqual(work.workers.count, BotDelegatedWork.maximumWorkers)
        XCTAssertEqual(work.omittedWorkerCount, 2)
        XCTAssertEqual(work.workers.prefix(2).map(\.subagentID), ["parent", "child"])
        XCTAssertEqual(work.workers[0].lastTool, "read_file")
        XCTAssertEqual(work.workers[1].goal, "Delegated worker")
        XCTAssertNil(work.workers[1].model)
    }

    func testTailIsLoadedOnlyOnDemandAndClientBoundsUnexpectedLargeText() async throws {
        let wire = BotDelegatedWorkWire()
        let row = worker(id: "child", startedAt: 1)
        wire.handler = { method, _ in
            switch method {
            case "subagent.list": return .object(["subagents": .array([row])])
            case "subagent.tail":
                return .object([
                    "subagent_id": .string("child"), "available": .bool(true),
                    "text": .string(String(repeating: "é", count: 12_000)), "truncated": .bool(false),
                    "future": .string("ignored")
                ])
            default: throw BotFailure.unsupported
            }
        }
        let work = BotDelegatedWork(wire: wire)
        await work.connect(context())
        XCTAssertEqual(wire.calls.map(\.method), ["subagent.list"])

        await work.loadTail(for: try XCTUnwrap(work.workers.first))

        let tail = try XCTUnwrap(work.tail)
        XCTAssertTrue(tail.available)
        XCTAssertTrue(tail.truncated)
        XCTAssertLessThanOrEqual(Data(tail.text.utf8).count, BotDelegatedWork.maximumTailBytes + 2)
        XCTAssertEqual(wire.calls.map(\.method), ["subagent.list", "subagent.tail"])
    }

    func testLateListReplyCannotPopulateADisconnectedGeneration() async {
        let wire = BotDelegatedWorkWire()
        let started = expectation(description: "list started")
        var release: CheckedContinuation<Void, Never>?
        wire.handler = { method, _ in
            XCTAssertEqual(method, "subagent.list")
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            return .object(["subagents": .array([self.worker(id: "late", startedAt: 1)])])
        }
        let work = BotDelegatedWork(wire: wire)
        let load = Task { await work.connect(context()) }
        await fulfillment(of: [started], timeout: 2)

        work.disconnect()
        release?.resume()
        await load.value

        XCTAssertEqual(work.availability, .unknown)
        XCTAssertTrue(work.workers.isEmpty)
    }

    func testCompletionAndIDReuseDuringConfirmationNeverInterruptAnotherWorker() async throws {
        for replacement in [nil, worker(id: "same", goal: "Replacement", startedAt: 2)] {
            let wire = BotDelegatedWorkWire()
            var listCount = 0
            wire.handler = { method, _ in
                switch method {
                case "subagent.list":
                    defer { listCount += 1 }
                    let rows = listCount == 0 ? [self.worker(id: "same", goal: "Original", startedAt: 1)] : replacement.map { [$0] } ?? []
                    return .object(["subagents": .array(rows)])
                case "subagent.interrupt":
                    XCTFail("A completed or replaced id must not be interrupted")
                    return .object(["found": .bool(true), "subagent_id": .string("same")])
                default: throw BotFailure.unsupported
                }
            }
            let work = BotDelegatedWork(wire: wire)
            await work.connect(context())
            let action = try XCTUnwrap(work.prepareInterrupt(try XCTUnwrap(work.workers.first)))

            await work.interrupt(action)

            XCTAssertEqual(wire.calls.filter { $0.method == "subagent.interrupt" }.count, 0)
            XCTAssertEqual(work.errorMessage, "This worker is no longer active.")
        }
    }

    func testDuplicateInterruptTapDispatchesOneIrreversibleCall() async throws {
        let wire = BotDelegatedWorkWire()
        let row = worker(id: "child", startedAt: 1)
        let dispatched = expectation(description: "interrupt dispatched")
        var release: CheckedContinuation<Void, Never>?
        wire.handler = { method, _ in
            switch method {
            case "subagent.list": return .object(["subagents": .array([row])])
            case "subagent.interrupt":
                await withCheckedContinuation { continuation in
                    release = continuation
                    dispatched.fulfill()
                }
                return .object(["found": .bool(true), "subagent_id": .string("child")])
            default: throw BotFailure.unsupported
            }
        }
        let work = BotDelegatedWork(wire: wire)
        await work.connect(context())
        let action = try XCTUnwrap(work.prepareInterrupt(try XCTUnwrap(work.workers.first)))
        let first = Task { await work.interrupt(action) }
        await fulfillment(of: [dispatched], timeout: 2)

        await work.interrupt(action)
        release?.resume()
        await first.value

        XCTAssertEqual(wire.calls.filter { $0.method == "subagent.interrupt" }.count, 1)
        XCTAssertEqual(work.interruptedWorker?.subagentID, "child")
    }

    func testInterruptNotFoundKeepsTheInactiveMessageAfterRefreshingTheRoster() async throws {
        let wire = BotDelegatedWorkWire()
        let row = worker(id: "child", startedAt: 1)
        var listCount = 0
        wire.handler = { method, _ in
            switch method {
            case "subagent.list":
                defer { listCount += 1 }
                return .object(["subagents": .array(listCount < 2 ? [row] : [])])
            case "subagent.interrupt":
                return .object(["found": .bool(false), "subagent_id": .string("child")])
            default: throw BotFailure.unsupported
            }
        }
        let work = BotDelegatedWork(wire: wire)
        await work.connect(context())
        let action = try XCTUnwrap(work.prepareInterrupt(try XCTUnwrap(work.workers.first)))

        await work.interrupt(action)

        XCTAssertTrue(work.workers.isEmpty)
        XCTAssertEqual(work.errorMessage, "This worker is no longer active.")
        XCTAssertEqual(wire.calls.map(\.method), ["subagent.list", "subagent.list", "subagent.interrupt", "subagent.list"])
    }

    func testUnsupportedMethodDegradesWithoutInventingWorkers() async {
        let wire = BotDelegatedWorkWire()
        wire.handler = { _, _ in throw BotFailure.rejected(-32601) }
        let work = BotDelegatedWork(wire: wire)

        await work.connect(context())

        XCTAssertEqual(work.availability, .unsupported)
        XCTAssertTrue(work.workers.isEmpty)
        XCTAssertNil(work.errorMessage)
    }

    func testEqualRuntimeAndProfileNamesStayWithTheirConnectionOwnedModels() async {
        let firstWire = BotDelegatedWorkWire()
        let secondWire = BotDelegatedWorkWire()
        firstWire.handler = { _, _ in .object(["subagents": .array([self.worker(id: "first", startedAt: 1)])]) }
        secondWire.handler = { _, _ in .object(["subagents": .array([self.worker(id: "second", startedAt: 2)])]) }
        let first = BotDelegatedWork(wire: firstWire)
        let second = BotDelegatedWork(wire: secondWire)

        await first.connect(context(connectionID: firstConnection, runtime: "same-runtime"))
        await second.connect(context(connectionID: UUID(), runtime: "same-runtime"))

        XCTAssertEqual(first.workers.map(\.subagentID), ["first"])
        XCTAssertEqual(second.workers.map(\.subagentID), ["second"])
    }

    private func context(connectionID: UUID? = nil, runtime: String = "runtime") -> BotDelegatedWork.Context {
        .init(connectionID: connectionID ?? firstConnection, runtime: runtime, generation: 1)
    }

    private func worker(id: String, parent: String? = nil, depth: Int = 0,
                        goal: String? = nil, startedAt: Double? = nil,
                        lastTool: String? = nil, extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields = extra
        fields["subagent_id"] = .string(id)
        if let parent { fields["parent_id"] = .string(parent) }
        fields["depth"] = .number(Double(depth))
        if let goal { fields["goal"] = .string(goal) }
        if let startedAt { fields["started_at"] = .number(startedAt) }
        if let lastTool { fields["last_tool"] = .string(lastTool) }
        return .object(fields)
    }
}

@MainActor private final class BotDelegatedWorkWire: BotTransport {
    struct Call {
        let method: String
        let params: [String: BotJSON]
    }

    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var handler: ((String, [String: BotJSON]) async throws -> BotJSON)?
    private(set) var calls: [Call] = []

    func connect() async throws {}
    func close() {}

    func call(_ method: String, _ params: [String: BotJSON],
              validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append(Call(method: method, params: params))
        guard let handler else { throw BotFailure.unsupported }
        return try await handler(method, params)
    }
}
