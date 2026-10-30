import XCTest
@testable import HermesMobile

@MainActor final class HermesBackgroundProcessesTests: XCTestCase {
    private let firstConnection = UUID()
    private let secondConnection = UUID()

    /// The synthetic `process.list` fixture: running and recently exited rows, one with
    /// only the required identity and future fields the model must ignore.
    private func recordedFixture() throws -> [BotJSON] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HermesAgent/process-list.json")
        guard let data = try? Data(contentsOf: file) else {
            throw XCTSkip("Could not read \(file.path); the source tree is not present (physical device or remote runner).")
        }
        let recorded = try JSONDecoder().decode(BotJSON.self, from: data)
        return try XCTUnwrap(recorded["processes"].list)
    }

    /// Listed running and recently exited rows stay inspectable, and a row with only the
    /// required identity survives: its tail falls back to `output_preview`, its unknown
    /// status is displayable, and a future host's extra fields change nothing.
    func testListedRowsRemainInspectableIncludingOneWithOnlyRequiredMetadata() throws {
        let rows = try recordedFixture()
        XCTAssertEqual(rows.count, 3)

        let running = try XCTUnwrap(HermesBackgroundProcess(rows[0]))
        XCTAssertEqual(running.processID, "bg-synthetic-running")
        XCTAssertEqual(running.command, "python3 -m http.server 8000")
        XCTAssertEqual(running.status, "running")
        XCTAssertEqual(running.uptime, "0:01:23")
        XCTAssertEqual(running.pid, 4242)
        XCTAssertFalse(running.isFinished)
        XCTAssertTrue(running.isStoppable)
        XCTAssertFalse(running.tailTruncated)
        XCTAssertFalse(running.tail?.contains("\u{1B}") ?? true, "The tail is ANSI-free")
        XCTAssertTrue(running.tail?.contains("Serving HTTP") ?? false)

        let exited = try XCTUnwrap(HermesBackgroundProcess(rows[1]))
        XCTAssertEqual(exited.processID, "bg-synthetic-exited")
        XCTAssertTrue(exited.isFinished)
        XCTAssertFalse(exited.isStoppable)
        XCTAssertEqual(exited.exitCode, 0)

        let minimal = try XCTUnwrap(HermesBackgroundProcess(rows[2]))
        XCTAssertEqual(minimal.processID, "bg-synthetic-minimal")
        XCTAssertNil(minimal.command)
        XCTAssertNil(minimal.status)
        XCTAssertEqual(minimal.tail, "waiting for input")
        XCTAssertNil(minimal.exitCode)
    }

    /// A row without usable identity is omitted, tails are ANSI-free and client-bounded,
    /// and the list itself is bounded.
    func testListDecodesTolerantlyStripsANSIAndBoundsRowsAndTails() async throws {
        let wire = HermesBackgroundProcessesWire()
        var rows: [BotJSON] = [
            .object(["output_tail": .string("no identity here")]),
            .object(["session_id": .string("  "), "command": .string("blank identity")]),
            .object(["session_id": .string("ansi"),
                     "status": .string("running"),
                     "output_tail": .string("progress \u{1B}[31mred\u{1B}[0m done")]),
            .object(["session_id": .string("preview-only"), "output_preview": .string("early lines")])
        ]
        rows.append(contentsOf: (0..<HermesBackgroundProcesses.maximumProcesses).map {
            .object(["session_id": .string("extra-\($0)"), "future": .array([])])
        })
        wire.handler = { method, _ in
            XCTAssertEqual(method, "process.list")
            return .object(["processes": .array(rows), "future": .bool(true)])
        }
        let processes = HermesBackgroundProcesses(wire: wire)

        await processes.connect(context())

        XCTAssertEqual(processes.availability, .supported)
        XCTAssertEqual(processes.processes.count, HermesBackgroundProcesses.maximumProcesses)
        XCTAssertEqual(processes.omittedProcessCount, 2)
        XCTAssertEqual(processes.runningCount, HermesBackgroundProcesses.maximumProcesses + 2)
        let ansi = try XCTUnwrap(processes.processes.first { $0.processID == "ansi" })
        XCTAssertEqual(ansi.tail, "progress red done")
        let preview = try XCTUnwrap(processes.processes.first { $0.processID == "preview-only" })
        XCTAssertEqual(preview.tail, "early lines")

        wire.handler = { _, _ in
            .object(["processes": .array([
                .object(["session_id": .string("huge"),
                         "output_tail": .string(String(repeating: "é", count: 12_000))])
            ])])
        }
        await processes.refresh()

        let huge = try XCTUnwrap(processes.processes.first)
        XCTAssertTrue(huge.tailTruncated)
        XCTAssertLessThanOrEqual(Data((huge.tail ?? "").utf8).count,
                                 HermesBackgroundProcesses.maximumTailBytes + 2)
    }

    /// Kill sends `session_id` = the attached runtime and `process_id` = the entry's
    /// `session_id`, and nothing else is asserted about the request.
    func testKillSendsTheRuntimeAndTheEntrySessionID() async throws {
        let wire = HermesBackgroundProcessesWire()
        let row = process(id: "bg-1", status: "running")
        wire.handler = { method, _ in
            switch method {
            case "process.list": return .object(["processes": .array([row])])
            case "process.kill": return .object(["status": .string("killed")])
            default: throw BotFailure.unsupported
            }
        }
        let processes = HermesBackgroundProcesses(wire: wire)
        await processes.connect(context())
        let action = try XCTUnwrap(processes.prepareStop(try XCTUnwrap(processes.processes.first)))

        await processes.stop(action)

        let kill = try XCTUnwrap(wire.calls.last { $0.method == "process.kill" })
        XCTAssertEqual(kill.params["session_id"]?.text, "runtime")
        XCTAssertEqual(kill.params["process_id"]?.text, "bg-1")
        let result = try XCTUnwrap(processes.result)
        XCTAssertTrue(result.isKilled)
        XCTAssertEqual(result.process, HermesBackgroundProcess.Identity(processID: "bg-1"))
    }

    /// A host without the RPC answers -32601 once; the connection's missing-method cache
    /// then hides the feature without another request and without an error message.
    func testMissingMethodHidesTheFeatureThroughTheConnectionCache() async {
        let wire = HermesBackgroundProcessesWire()
        var listCount = 0
        wire.handler = { method, _ in
            defer { listCount += 1 }
            XCTAssertEqual(method, "process.list")
            if listCount == 0 {
                // The gateway itself notes the method on the shared connection
                // (HermesGateway.consume); the wire double mirrors that here.
                wire.unavailableMethods.insert(method)
                throw BotFailure.rejected(-32601)
            }
            return .object(["processes": .array([])])
        }
        let processes = HermesBackgroundProcesses(wire: wire)
        await processes.connect(context())

        XCTAssertEqual(processes.availability, .unsupported)
        XCTAssertTrue(processes.processes.isEmpty)
        XCTAssertNil(processes.errorMessage)
        XCTAssertEqual(wire.calls.count, 1)

        // A later refresh — a turn's end, the sheet, or a pull — sends nothing further.
        await processes.refresh()
        XCTAssertEqual(wire.calls.count, 1)
        XCTAssertEqual(processes.availability, .unsupported)
    }

    /// A list or kill reply that arrives after a reattach is dropped, whatever it carried.
    func testAReplyArrivingAfterAReattachIsDropped() async {
        let wire = HermesBackgroundProcessesWire()
        let listed = expectation(description: "list started")
        var release: CheckedContinuation<Void, Never>?
        var hasBlocked = false
        wire.handler = { method, _ in
            XCTAssertEqual(method, "process.list")
            if hasBlocked { return .object(["processes": .array([])]) }
            hasBlocked = true
            await withCheckedContinuation { continuation in
                release = continuation
                listed.fulfill()
            }
            return .object(["processes": .array([self.process(id: "late", status: "running")])])
        }
        let processes = HermesBackgroundProcesses(wire: wire)
        let load = Task { await processes.connect(context()) }
        await fulfillment(of: [listed], timeout: 2)

        await processes.connect(context(connectionID: secondConnection))
        release?.resume()
        await load.value

        XCTAssertTrue(processes.processes.isEmpty, "The old generation's rows never install")
        XCTAssertEqual(processes.availability, .supported, "The new attach listed its own (empty) roster")
    }

    /// A stale confirmation — the process exited, or its id is gone — sends no kill.
    /// An `error` or unknown result never produces success, and `not_found`/4044 refresh.
    func testStaleConfirmationErrorAndNotFoundNeverReportSuccess() async throws {
        // The re-list during confirmation no longer reports the process.
        do {
            let wire = HermesBackgroundProcessesWire()
            var listCount = 0
            wire.handler = { method, _ in
                switch method {
                case "process.list":
                    defer { listCount += 1 }
                    return .object(["processes": .array(listCount == 0 ? [self.process(id: "bg-1", status: "running")] : [])])
                case "process.kill":
                    XCTFail("An exited or replaced process must not be killed")
                    return .object(["status": .string("killed")])
                default: throw BotFailure.unsupported
                }
            }
            let processes = HermesBackgroundProcesses(wire: wire)
            await processes.connect(context())
            let action = try XCTUnwrap(processes.prepareStop(try XCTUnwrap(processes.processes.first)))

            await processes.stop(action)

            XCTAssertEqual(wire.calls.filter { $0.method == "process.kill" }.count, 0)
            XCTAssertNil(processes.result)
            XCTAssertEqual(processes.errorMessage, "This process is no longer running.")
        }

        // An `error` result keeps the row and shows the failure, never success.
        do {
            let wire = HermesBackgroundProcessesWire()
            let row = process(id: "bg-1", status: "running")
            wire.handler = { method, _ in
                switch method {
                case "process.list": return .object(["processes": .array([row])])
                case "process.kill":
                    return .object(["status": .string("error"), "error": .string("the process remains running")])
                default: throw BotFailure.unsupported
                }
            }
            let processes = HermesBackgroundProcesses(wire: wire)
            await processes.connect(context())
            let action = try XCTUnwrap(processes.prepareStop(try XCTUnwrap(processes.processes.first)))

            await processes.stop(action)

            XCTAssertNil(processes.result)
            XCTAssertEqual(processes.errorMessage, "The host could not stop this process.")
            XCTAssertEqual(processes.processes.map(\.processID), ["bg-1"])
        }

        // An unknown status is the same: row kept, no success.
        do {
            let wire = HermesBackgroundProcessesWire()
            let row = process(id: "bg-1", status: "running")
            wire.handler = { method, _ in
                switch method {
                case "process.list": return .object(["processes": .array([row])])
                case "process.kill": return .object(["status": .string("mystery"), "future": .bool(true)])
                default: throw BotFailure.unsupported
                }
            }
            let processes = HermesBackgroundProcesses(wire: wire)
            await processes.connect(context())
            let action = try XCTUnwrap(processes.prepareStop(try XCTUnwrap(processes.processes.first)))

            await processes.stop(action)

            XCTAssertNil(processes.result)
            XCTAssertEqual(processes.errorMessage, "The host could not stop this process.")
            XCTAssertEqual(processes.processes.map(\.processID), ["bg-1"])
        }

        // `not_found` and RPC 4044 refresh instead of failing, and never report success.
        let outcomes: [(kill: BotJSON?, failure: BotFailure?)] = [
            (.object(["status": .string("not_found")]), nil),
            (nil, .rejected(4044))
        ]
        for outcome in outcomes {
            let wire = HermesBackgroundProcessesWire()
            var listCount = 0
            wire.handler = { method, _ in
                switch method {
                case "process.list":
                    defer { listCount += 1 }
                    return .object(["processes": .array(listCount < 2 ? [self.process(id: "bg-1", status: "running")] : [])])
                case "process.kill":
                    if let failure = outcome.failure { throw failure }
                    return outcome.kill!
                default: throw BotFailure.unsupported
                }
            }
            let processes = HermesBackgroundProcesses(wire: wire)
            await processes.connect(context())
            let action = try XCTUnwrap(processes.prepareStop(try XCTUnwrap(processes.processes.first)))

            await processes.stop(action)

            XCTAssertNil(processes.result)
            XCTAssertTrue(processes.processes.isEmpty, "The refresh replaced the gone row")
            XCTAssertEqual(wire.calls.filter { $0.method == "process.list" }.count, 3,
                           "Connect, the pre-dispatch re-list, and the refresh after the refusal")
        }
    }

    private func context(connectionID: UUID? = nil, runtime: String = "runtime") -> HermesBackgroundProcesses.Context {
        .init(connectionID: connectionID ?? firstConnection, runtime: runtime, generation: 1)
    }

    private func process(id: String, status: String?, extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields = extra
        fields["session_id"] = .string(id)
        if let status { fields["status"] = .string(status) }
        fields["command"] = .string("sleep 600")
        return .object(fields)
    }
}

@MainActor private final class HermesBackgroundProcessesWire: BotTransport {
    struct Call {
        let method: String
        let params: [String: BotJSON]
    }

    var replayEpoch: String? = "epoch"
    var unavailableMethods: Set<String> = []
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var handler: ((String, [String: BotJSON]) async throws -> BotJSON)?
    private(set) var calls: [Call] = []

    func connect() async throws {}
    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let method = call.method, params = try call.params()
        try validateDispatch?()
        calls.append(Call(method: method, params: params))
        guard let handler else { throw BotFailure.unsupported }
        return try await handler(method, params)
    }
}
