import XCTest
@testable import HermesMobile

@MainActor final class BotAvatarStudioTests: XCTestCase {
    private var cat: BotAvatarCatalog.Entry { BotAvatarCatalog.entries.first { $0.definition.id == "cat" }! }

    private func studio(look: [String: BotJSON] = [:], hadPhoto: Bool = false) -> BotAvatarStudio {
        BotAvatarStudio(name: "scout", appearance: BotProfileAppearance(look: look, fallbackTitle: "Scout"),
                        hadPhoto: hadPhoto, sendPrompt: nil)
    }

    func testADrawnAvatarSurvivesTheLookAndDesktopKeysStay() {
        let drawn = BotDrawnAvatar(definition: cat.definition, depth: 9, eyeColor: "#112233")
        var appearance = BotProfileAppearance(look: [:], fallbackTitle: "Scout")
        appearance.drawn = drawn

        let written = appearance.merging(into: ["sectionId": .string("desktop"), "shape": .string("cloud")])

        XCTAssertEqual(written["sectionId"], .string("desktop"))
        XCTAssertEqual(BotProfileAppearance(look: written, fallbackTitle: "Scout").drawn, drawn)
    }

    func testAValueThisBuildCannotReadIsKeptUntilTheUserPicksAFace() {
        let stored: [String: BotJSON] = [BotDrawnAvatar.lookKey: .object(["futureFormat": .bool(true)])]
        let appearance = BotProfileAppearance(look: stored, fallbackTitle: "Scout")
        XCTAssertNil(appearance.drawn)
        XCTAssertEqual(appearance.merging(into: stored)[BotDrawnAvatar.lookKey], stored[BotDrawnAvatar.lookKey])

        var picked = appearance
        picked.drawn = nil
        XCTAssertNil(picked.merging(into: stored)[BotDrawnAvatar.lookKey])
    }

    func testPickingAvatarsAndClassicsKeepsTheStoredShapeForDesktop() {
        let studio = studio(look: ["shape": .string("cloud"), "custom": .bool(true)])

        studio.pick(cat)
        XCTAssertEqual(studio.appearance.shape, "cloud", "Desktop keeps drawing the shape it has")
        XCTAssertEqual(studio.appearance.color, cat.color)
        XCTAssertEqual(studio.depth, BotDrawnAvatar.naturalDepth)

        studio.pick(.pill)
        XCTAssertNil(studio.appearance.drawn, "a plain classic stores nothing extra")
        XCTAssertEqual(studio.appearance.shape, "pill")
        XCTAssertEqual(studio.depth, 0)
    }

    func testAClassicTakesDepthAndGoesBackToItsExactFlatFace() {
        let studio = studio(look: ["shape": .string("hexagon"), "color": .string("#22c55e"), "custom": .bool(true)])

        studio.setDepth(8)
        XCTAssertEqual(studio.appearance.drawn?.definition.id, "classic-hexagon")
        XCTAssertEqual(studio.appearance.drawn?.lean, BotAvatarClassic.lean)

        studio.setDepth(0)
        XCTAssertNil(studio.appearance.drawn)
    }

    func testResetReturnsToTheNameSeededFace() {
        let studio = studio(look: ["shape": .string("cloud"), "custom": .bool(true)])
        studio.pick(cat)
        studio.setExpression(.sad)

        studio.reset()

        XCTAssertNil(studio.appearance.drawn); XCTAssertNil(studio.appearance.shape)
        XCTAssertNil(studio.appearance.expression); XCTAssertFalse(studio.appearance.custom)
    }

    func testOnlyABodyChangeReplacesAPhoto() {
        let studio = studio(hadPhoto: true)
        studio.setExpression(.sad)
        XCTAssertFalse(studio.replacesPhoto)
        studio.pick(cat)
        XCTAssertTrue(studio.replacesPhoto)
    }

    func testEyesOutsideTheBodyAreRefusedAndValidOnesAreTaken() async {
        let studio = studio()
        studio.pick(cat)
        let start = studio.eyes

        await studio.propose(eyes: .init(x: 2, y: 2, spacing: start.spacing, scale: start.scale)).value
        XCTAssertEqual(studio.eyes, start)

        await studio.propose(eyes: .init(x: start.x + 1, y: start.y, spacing: start.spacing, scale: start.scale)).value
        XCTAssertEqual(studio.eyes.x, start.x + 1)

        studio.resetEyes()
        XCTAssertEqual(studio.eyes, start)
    }

    func testImportShowsTheValidatorsErrorsAndExportReadsBack() async throws {
        let studio = studio()
        let refused = await studio.importDefinition(Data(#"{"version":1,"id":"x","extra":true}"#.utf8))
        XCTAssertFalse(refused)
        XCTAssertTrue(studio.importErrors.contains { $0.contains("extra") })

        studio.pick(cat)
        let exported = studio.exportText
        studio.reset()
        let taken = await studio.importDefinition(Data(exported.utf8))
        XCTAssertTrue(taken)
        XCTAssertEqual(studio.appearance.drawn?.definition, cat.definition)
        XCTAssertTrue(studio.importErrors.isEmpty)
    }

    func testEveryClassicDefinitionPrepares() throws {
        for shape in BotAvatarShape.allCases {
            let definition = BotAvatarClassic.definition(shape)
            XCTAssertNoThrow(try BotAvatarVolume.prepare(definition, depth: 6), shape.rawValue)
            XCTAssertEqual(BotAvatarClassic.shape(of: definition), shape)
        }
    }

    func testEveryExpressionFitsANarrowBody() throws {
        let definition = try XCTUnwrap(BotAvatarCatalog.entries.first { $0.definition.id == "witch-hat" }).definition
        let volume = try BotAvatarVolume.prepare(definition, depth: 6)
        for expression in BotAvatarExpression.allCases {
            let layout = BotAvatarEyeLayout.fit(volume: volume, geometry: expression.geometry, happy: expression.isArc)
            XCTAssertGreaterThan(layout.scale, 0, expression.rawValue)
        }
    }

    func testAStoredDefinitionThatFailsValidationBuildsOnceAndFails() async {
        let store = BotAvatarRenderStore()
        let bad = BotDrawnAvatar(definition: BotAvatarDefinition(version: 1, id: "bad", name: "Bad", body: .init(path: "not a path"),
                                                                 eyes: .init(x: 50, y: 50, spacing: 15, scale: 1)), depth: 6)
        let key = BotAvatarRenderStore.key(bad, expression: nil)
        let built = await store.face(for: key)
        XCTAssertNil(built)
        XCTAssertTrue(store.hasFailed(key))
    }

    func testASynchronousCallerGetsAStillOnceTheFaceIsBuilt() async throws {
        var appearance = BotProfileAppearance(look: [:], fallbackTitle: "Scout")
        let unique = BotAvatarDefinition(version: 1, id: "still-test", name: "Still", body: .init(path: "M20 20 H80 V80 H20 Z"),
                                         eyes: .init(x: 50, y: 46, spacing: 15, scale: 1))
        appearance.drawn = BotDrawnAvatar(definition: unique, depth: 6)
        appearance.color = "#22c55e"
        let key = try XCTUnwrap(appearance.renderKey)
        XCTAssertNil(appearance.drawnStill(name: "scout", pointSize: 40, scale: 3, dark: true), "never blocks to build")

        _ = await BotAvatarRenderStore.shared.face(for: key)

        let still = try XCTUnwrap(appearance.drawnStill(name: "scout", pointSize: 40, scale: 3, dark: true))
        XCTAssertEqual(still.cgImage?.width, 120)
    }

    func testTheRenderStoreIsBoundedAndARepeatIsAHit() async {
        let store = BotAvatarRenderStore(limit: 2)
        let keys = BotAvatarCatalog.entries.prefix(3).map {
            BotAvatarRenderStore.key(BotDrawnAvatar(definition: $0.definition, depth: 0), expression: nil)
        }
        for key in keys { _ = await store.face(for: key) }
        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.cached(keys[0]))
        XCTAssertNotNil(store.cached(keys[2]))
    }
}

/// "Describe it" over a scripted socket.
@MainActor final class BotAvatarGenerationTests: XCTestCase {
    private let valid = """
    {"version":1,"id":"box","name":"Box","body":{"path":"M20 20 H80 V80 H20 Z"},"eyes":{"x":50,"y":46,"spacing":15,"scale":1}}
    """

    func testAFencedAnswerIsRead() throws {
        guard case .valid(let definition) = BotAvatarGeneration.read("Here you go:\n```json\n\(valid)\n```") else {
            return XCTFail("a fenced answer should read")
        }
        XCTAssertEqual(definition.id, "box")
    }

    func testABadAnswerGetsOneRepairWithTheValidatorsErrors() async throws {
        var prompts: [String] = []
        let answers = ["not json", valid]
        let definition = try await BotAvatarGeneration.definition(description: "a box") { prompt in
            prompts.append(prompt)
            return answers[prompts.count - 1]
        }
        XCTAssertEqual(definition.id, "box")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("a box"))
        XCTAssertTrue(prompts[1].contains("no JSON object"))
    }

    func testTwoBadAnswersFailWithoutAThirdTry() async {
        var asks = 0
        do {
            _ = try await BotAvatarGeneration.definition(description: "a box") { _ in asks += 1; return "nope" }
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

    func testStoppingWaitingEndsTheCallAndCleansUp() async throws {
        let wire = GenerationWire()
        let accepted = expectation(description: "the host took the prompt")
        wire.onBtw = { _ in accepted.fulfill() }
        let task = Task { try await BotAvatarGeneration.ask("prompt", profile: "scout", transport: wire, validateDispatch: nil) }
        await fulfillment(of: [accepted], timeout: 5)

        task.cancel()

        do { _ = try await task.value; XCTFail("should stop") } catch { XCTAssertTrue(error is CancellationError) }
        await wire.waitForCleanup()
        XCTAssertTrue(wire.methods.contains("session.close"))
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
}

@MainActor private final class GenerationWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onBtw: ((GenerationWire) -> Void)?
    var methods: [String] = []
    var params: [[String: BotJSON]] = []
    private var cleanup: CheckedContinuation<Void, Never>?
    private var cleaned = false

    func connect() async throws {}
    func close() {}

    func send(_ runtime: String, task: String, text: String) {
        onEvent?(.object(["type": .string("btw.complete"), "session_id": .string(runtime),
                          "payload": .object(["task_id": .string(task), "text": .string(text)])]))
    }

    func waitForCleanup() async {
        if cleaned { return }
        await withCheckedContinuation { cleanup = $0 }
    }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        methods.append(call.method)
        params.append(try call.params())
        switch call.method {
        case "session.create": return .object(["session_id": .string("draft-1"), "stored_session_id": .string("stored-1")])
        case "prompt.btw":
            onBtw?(self)
            return .object(["task_id": .string("t1")])
        case "session.delete":
            cleaned = true
            cleanup?.resume(); cleanup = nil
            return .object(["deleted": .string("stored-1")])
        default: return .object([:])
        }
    }
}
