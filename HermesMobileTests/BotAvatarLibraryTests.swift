import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor final class BotAvatarLibraryTests: XCTestCase {
    private func profile(_ name: String) -> BotProfile { BotProfile(.object(["name": .string(name)]))! }

    func testEveryReadyMadeAvatarDrawsWithItsEyesOnTheBody() throws {
        let readyMade = BotAvatarShape.allCases.filter { !BotAvatarShape.classic.contains($0) }
        XCTAssertEqual(readyMade.count, 21)
        for shape in readyMade {
            let entry = try XCTUnwrap(shape.readyMade, shape.rawValue)
            XCTAssertNotNil(BotAvatarPathData.path(entry.path), shape.rawValue)
            XCTAssertEqual(BotGeneratedAvatar(name: "x", path: entry.path, eyes: entry.eyes).problems, [], shape.rawValue)
        }
    }

    func testNameSeededFacesOnlyUseTheClassicShapes() {
        XCTAssertEqual(BotAvatarShape.classic.map(\.rawValue), ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"])
        XCTAssertTrue(BotAvatarShape.classic.allSatisfy { $0.readyMade == nil })
    }

    func testAnAnswerInACodeFenceIsReadAndABadPathIsExplained() throws {
        let good = #"{"name":"Box","path":"M20 20 L80 20 L80 80 L20 80 Z","eyes":{"x":50,"y":46,"spacing":16,"scale":1.2}}"#
        let avatar = try BotGeneratedAvatar.read(answer: "Sure:\n```json\n\(good)\n```").get()
        XCTAssertEqual(avatar.name, "Box")

        let arc = #"{"name":"Box","path":"M20 20 A5 5 0 0 1 80 80 Z","eyes":{"x":50,"y":46,"spacing":16,"scale":1.2}}"#
        guard case .failure(.unreadable(let problems)) = BotGeneratedAvatar.read(answer: arc) else { return XCTFail("arcs are not in the grammar") }
        XCTAssertTrue(problems[0].contains("M, L, Q, C and Z"))

        let offBody = #"{"name":"Box","path":"M20 20 L80 20 L80 80 L20 80 Z","eyes":{"x":14,"y":46,"spacing":16,"scale":1.2}}"#
        guard case .failure(.unreadable(let eyes)) = BotGeneratedAvatar.read(answer: offBody) else { return XCTFail("eyes are off the body") }
        XCTAssertTrue(eyes.contains { $0.contains("eyes") })
    }

    func testAGeneratedAvatarRoundTripsAndKeepsANewerBuildsFieldsUntilAFaceIsPicked() {
        let avatar = BotGeneratedAvatar(name: "Box", path: "M20 20 L80 20 L80 80 L20 80 Z", eyes: BotAvatarEyes(x: 50, y: 46, spacing: 16, scale: 1.2))
        var stored = avatar.json.fields ?? [:]
        stored["futureField"] = .string("kept")
        let look: [String: BotJSON] = [BotGeneratedAvatar.lookKey: .object(stored), "sectionId": .string("desktop")]

        var appearance = BotProfileAppearance(look: look, fallbackTitle: "Scout")
        XCTAssertEqual(appearance.generated, avatar)
        appearance.title = "Renamed"
        XCTAssertEqual(appearance.merging(into: look)[BotGeneratedAvatar.lookKey]?["futureField"], .string("kept"))
        XCTAssertEqual(appearance.merging(into: look)["sectionId"], .string("desktop"))

        appearance.generated = nil
        XCTAssertNil(appearance.merging(into: look)[BotGeneratedAvatar.lookKey])
    }

    func testABadPathOrAnUnreadableValueNeverBlocksTheFace() {
        XCTAssertNil(BotAvatarPathData.path("M10 10 X5 5"))
        XCTAssertNil(BotAvatarPathData.path("L10 10 Z"), "a line needs a move first")
        XCTAssertNil(BotProfileAppearance(look: [BotGeneratedAvatar.lookKey: .object(["future": .bool(true)])], fallbackTitle: "Scout").generated)
    }
}

/// "Describe It" over a scripted socket.
@MainActor final class BotAvatarGenerationTests: XCTestCase {
    private let valid = #"{"name":"Box","path":"M20 20 L80 20 L80 80 L20 80 Z","eyes":{"x":50,"y":46,"spacing":16,"scale":1.2}}"#

    func testABadAnswerGetsOneRepairWithItsProblems() async throws {
        var prompts: [String] = []
        let answers = ["not json", valid]
        let avatar = try await BotAvatarGeneration.avatar(description: "a box") { prompt in
            prompts.append(prompt)
            return answers[prompts.count - 1]
        }
        XCTAssertEqual(avatar.name, "Box")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("a box"))
        XCTAssertTrue(prompts[1].contains("not the requested JSON"))
    }

    func testTwoBadAnswersFailWithoutAThirdTry() async {
        var asks = 0
        do {
            _ = try await BotAvatarGeneration.avatar(description: "a box") { _ in asks += 1; return "nope" }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(asks, 2)
            XCTAssertTrue(error is BotAvatarGeneration.Failure)
        }
    }

    func testAskUsesTheToolFreeCallAdmitsOnlyItsOwnAnswerAndCleansUp() async throws {
        let wire = GenerationWire()
        wire.onBtw = { wire in
            wire.send("other-runtime", task: "t1", text: "not mine")
            wire.send("draft-1", task: "someone-else", text: "not mine either")
            wire.send("draft-1", task: "t1", text: "the answer")
        }
        let answer = try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil)
        await wire.waitForCleanup()

        XCTAssertEqual(answer, "the answer")
        XCTAssertEqual(wire.methods, ["session.create", "prompt.btw", "session.close", "session.delete"])
        XCTAssertEqual(wire.params[0]["profile"], .string("scout"))
        XCTAssertEqual(wire.params[0]["hidden"], .bool(true))
        XCTAssertEqual(wire.params[3]["session_id"], .string("stored-1"))
    }

    func testADraftStillClosingIsDeletedOnALaterTry() async throws {
        BotAvatarGeneration.deleteRetryDelay = .zero
        defer { BotAvatarGeneration.deleteRetryDelay = .seconds(2) }
        let wire = GenerationWire()
        wire.refusedDeletes = 2
        wire.onBtw = { $0.send("draft-1", task: "t1", text: "the answer") }

        _ = try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil)
        await wire.waitForCleanup()

        XCTAssertEqual(wire.methods.filter { $0 == "session.delete" }.count, 3)
    }

    func testAHostErrorIsAFailureAndStillCleansUp() async throws {
        let wire = GenerationWire()
        wire.onBtw = { $0.send("draft-1", task: "t1", text: "error: no model") }
        do {
            _ = try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil)
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? BotAvatarGeneration.Failure, .host("no model"))
        }
        await wire.waitForCleanup()
        XCTAssertTrue(wire.methods.contains("session.delete"))
    }

    func testStoppingWhileTheDraftOpensNeverSendsThePrompt() async throws {
        let wire = GenerationWire()
        let opening = expectation(description: "the draft is opening")
        wire.onCreate = { opening.fulfill() }
        wire.holdsCreate = true
        let task = Task { try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil) }
        await fulfillment(of: [opening], timeout: 5)

        task.cancel()
        await Task.yield()
        wire.releaseCreate()

        do { _ = try await task.value; XCTFail("should stop") } catch { XCTAssertTrue(error is CancellationError) }
        await wire.waitForCleanup()
        XCTAssertEqual(wire.methods, ["session.create", "session.close", "session.delete"])
    }

    func testADroppedSocketFailsTheWait() async throws {
        let wire = GenerationWire()
        wire.onBtw = { $0.onDisconnect?(BotFailure.stale) }
        do {
            _ = try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil)
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? BotAvatarGeneration.Failure, .disconnected)
        }
    }

    func testARetryWaitsForTheStoppedCallToLetGoOfTheSocket() async throws {
        let held = HeldSend()
        let describer = BotAvatarDescriber(send: { try await held.send($0) }, onResult: { _ in })
        let first = expectation(description: "the first call is out")
        held.onSend = { first.fulfill() }
        describer.generate(description: "a box")
        await fulfillment(of: [first], timeout: 5)

        describer.stopWaiting()
        describer.generate(description: "a ball")
        await Task.yield()
        XCTAssertEqual(held.calls, 1, "the retry must not start while the first holds the handlers")

        let second = expectation(description: "the retry starts")
        held.onSend = { second.fulfill() }
        held.release(throwing: CancellationError())
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(held.calls, 2)
        describer.stopWaiting()
        held.release(throwing: CancellationError())
    }
}

/// A model call that stays out until the test lets it go.
@MainActor private final class HeldSend {
    var onSend: (() -> Void)?
    private(set) var calls = 0
    private var held: CheckedContinuation<String, Error>?

    func send(_ prompt: String) async throws -> String {
        calls += 1
        onSend?()
        return try await withCheckedThrowingContinuation { held = $0 }
    }

    func release(throwing error: Error) {
        held?.resume(throwing: error)
        held = nil
    }
}

@MainActor private final class GenerationWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onBtw: ((GenerationWire) -> Void)?
    var onCreate: (() -> Void)?
    var holdsCreate = false
    var refusedDeletes = 0
    var methods: [String] = []
    var params: [[String: BotJSON]] = []
    private var heldCreate: CheckedContinuation<Void, Never>?
    private var cleanup: CheckedContinuation<Void, Never>?
    private var cleaned = false

    func connect() async throws {}
    func close() {}

    func send(_ runtime: String, task: String, text: String) {
        onEvent?(.object(["type": .string("btw.complete"), "session_id": .string(runtime),
                          "payload": .object(["task_id": .string(task), "text": .string(text)])]))
    }

    func releaseCreate() { heldCreate?.resume(); heldCreate = nil }

    func waitForCleanup() async {
        if cleaned { return }
        await withCheckedContinuation { cleanup = $0 }
    }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        methods.append(call.method)
        params.append(try call.params())
        switch call.method {
        case "session.create":
            onCreate?()
            if holdsCreate { await withCheckedContinuation { heldCreate = $0 } }
            return .object(["session_id": .string("draft-1"), "stored_session_id": .string("stored-1")])
        case "prompt.btw":
            onBtw?(self)
            return .object(["task_id": .string("t1")])
        case "session.delete":
            if refusedDeletes > 0 {
                refusedDeletes -= 1
                throw BotFailure.rejected(4023)
            }
            cleaned = true
            cleanup?.resume(); cleanup = nil
            return .object(["deleted": .string("stored-1")])
        default: return .object([:])
        }
    }
}
