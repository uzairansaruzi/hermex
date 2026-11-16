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

    func testChipsRedrawWhenOnlyAGeneratedAvatarsEyesChange() {
        func token(x: Double) -> NSObject {
            let avatar = BotGeneratedAvatar(name: "Box", path: "M20 20 L80 20 L80 80 L20 80 Z", eyes: BotAvatarEyes(x: x, y: 46, spacing: 16, scale: 1.2))
            let row = BotJSON.object(["name": .string("scout"), "ui_meta": .object(["hermes-bots": .object([BotGeneratedAvatar.lookKey: avatar.json])])])
            return ComposerChipIcon.bot(ComposerBotReference(profile: BotProfile(row)!, avatar: nil)).cacheKey
        }
        XCTAssertNotEqual(token(x: 50), token(x: 48))
    }

    func testStoredEyesOutOfRangeDrawTheShapeButSurviveASave() {
        let bad = BotGeneratedAvatar(name: "Box", path: "M20 20 L80 20 L80 80 L20 80 Z", eyes: BotAvatarEyes(x: 50, y: 46, spacing: 16, scale: -3))
        XCTAssertFalse(bad.hasDrawableEyes)
        let look: [String: BotJSON] = [BotGeneratedAvatar.lookKey: bad.json]
        XCTAssertEqual(BotProfileAppearance(look: look, fallbackTitle: "Scout").merging(into: look)[BotGeneratedAvatar.lookKey], bad.json)
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
        let answers = ["{}", valid]
        let avatar = try await BotAvatarGeneration.avatar(description: "a box") { prompt in
            prompts.append(prompt)
            return answers[prompts.count - 1]
        }
        XCTAssertEqual(avatar.name, "Box")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("a box"))
        XCTAssertTrue(prompts[1].contains("not the requested JSON"))
    }

    func testAHostsPlainTextAnswerReachesTheUserWithNoRepairTry() async {
        let said = "OpenCode Go rejected your API key, so the model can't be reached."
        var asks = 0
        do {
            _ = try await BotAvatarGeneration.avatar(description: "a box") { _ in asks += 1; return said }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(asks, 1, "a repair try can't fix this, and costs another call")
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, said)
        }
    }

    func testAProviderFailureHoldingJSONIsStillTheHostsWords() {
        let said = "OpenCode Go rejected your API key.\n\nProvider said: HTTP 401: {\"error\":\"expired\"}"
        guard case .failure(.said(let text)) = BotGeneratedAvatar.read(answer: said) else { return XCTFail("not an avatar to repair") }
        XCTAssertEqual(text, said)
    }

    func testARealAnswerFromTheModelIsAccepted() throws {
        let answer = #"""
        {"name":"Pumpkin","path":"M 32 72 C 30 58 38 53 44 54 C 46 51 48 50 50 50 C 52 50 54 51 56 54 C 62 53 70 58 68 72 C 67 82 60 85 50 85 C 40 85 33 82 32 72 Z M 45 54 L 45 47 C 45 43 50 41 54 42 C 56 43 55 49 55 54 Z","eyes":{"x":50,"y":66,"spacing":14,"scale":1.15}}
        """#
        XCTAssertEqual(try BotGeneratedAvatar.read(answer: answer).get().name, "Pumpkin")
    }

    func testTwoBadAnswersFailWithoutAThirdTry() async {
        var asks = 0
        do {
            _ = try await BotAvatarGeneration.avatar(description: "a box") { _ in asks += 1; return "{}" }
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

    func testASecondCallWaitsForAStoppedOneToLetGoOfTheSocket() async throws {
        let wire = GenerationWire()
        let opening = expectation(description: "the first draft is opening")
        wire.onCreate = { opening.fulfill() }
        wire.holdsCreate = true
        let first = Task { try await BotAvatarGeneration.ask("first", profile: "scout", transport: wire, validateDispatch: nil) }
        await fulfillment(of: [opening], timeout: 5)
        first.cancel()

        wire.holdsCreate = false
        wire.onCreate = nil
        wire.onBtw = { $0.send("draft-1", task: "t1", text: "the answer") }
        let second = Task { try await BotAvatarGeneration.ask("second", profile: "scout", transport: wire, validateDispatch: nil) }
        await Task.yield()
        XCTAssertEqual(wire.methods, ["session.create"], "the second must not start while the first holds the socket")

        wire.releaseCreate()
        let answer = try await second.value
        XCTAssertEqual(answer, "the answer")
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
