import UIKit
import XCTest
@testable import HermesMobile

@MainActor final class BotAvatarTests: XCTestCase {
    private func row(_ name: String, extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields: [String: BotJSON] = ["name": .string(name)]
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }

    private func png(side: Int) -> String { botAvatarDataURL(side: side) }

    private func found(_ dataURL: String) -> BotJSON {
        .object(["found": .bool(true), "mime": .string("image/png"), "size": .number(1), "data": .string(dataURL)])
    }

    func testIdentityUsesDesktopTitleThenDisplayNameThenProfileName() {
        let bare = BotProfile(row("inbox-triage"))!
        XCTAssertEqual(bare.name, "inbox-triage")
        XCTAssertNil(bare.description)
        XCTAssertFalse(bare.hasAvatar)
        XCTAssertNil(bare.lookRevision)
        XCTAssertEqual(BotProfile(row("default"))!.name, "Hermes")

        let renamed = BotProfile(row("dev", extra: ["display_name": .string("  Dev Bot "), "description": .string("Ships code")]))!
        XCTAssertEqual(renamed.name, "Dev Bot")
        XCTAssertEqual(renamed.description, "Ships code")

        let titled = BotProfile(row("dev", extra: [
            "display_name": .string("Dev Bot"), "description": .string("Ships code"), "has_avatar": .bool(true),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Codey"), "description": .string("Pairs on PRs"), "shape": .string("hexagon")])]),
            "ui_meta_revisions": .object(["hermes-bots": .number(7)])
        ]))!
        XCTAssertEqual(titled.name, "Codey")
        XCTAssertEqual(titled.description, "Pairs on PRs")
        XCTAssertTrue(titled.hasAvatar)
        XCTAssertEqual(titled.lookRevision, 7)

        let blankTitle = BotProfile(row("dev", extra: ["display_name": .string("Dev Bot"), "ui_meta": .object(["hermes-bots": .object(["title": .string("   ")])])]))!
        XCTAssertEqual(blankTitle.name, "Dev Bot")
    }

    func testRefreshFetchesOnlyFlaggedRowsAndKeepsTheRosterOnBadImages() async {
        let store = BotAvatarStore()
        let wire = BotAvatarFixtureWire()
        wire.assets = [
            "good": found(png(side: 4)),
            "corrupt": found("data:image/png;base64,AAAA"),
            "notImage": .object(["found": .bool(true), "data": .string("data:text/plain;base64,aGVsbG8=")]),
            "gone": .object(["found": .bool(false)])
        ]
        let profiles = ["good", "corrupt", "notImage", "gone", "plain"].map { name in
            BotProfile(row(name, extra: ["has_avatar": .bool(name != "plain")]))!
        }
        let connection = UUID()
        var updates = 0
        await store.refresh(profiles, connectionID: connection, using: wire) { updates += 1 }
        XCTAssertEqual(wire.calls.map { $0.1["name"]?.text }, ["good", "corrupt", "notImage", "gone"])
        XCTAssertEqual(wire.calls.map { $0.1["asset"]?.text }, Array(repeating: "avatar", count: 4))
        XCTAssertEqual(Array(store.images(connectionID: connection).keys), ["good"])
        XCTAssertEqual(updates, 5)
    }

    func testRevisionKeepsCachedImagesAndMissingRevisionRefetches() async {
        let store = BotAvatarStore()
        let wire = BotAvatarFixtureWire()
        wire.assets = ["pinned": found(png(side: 4)), "loose": found(png(side: 4))]
        let connection = UUID()
        let pinned = BotProfile(row("pinned", extra: ["has_avatar": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(3)])]))!
        let loose = BotProfile(row("loose", extra: ["has_avatar": .bool(true)]))!
        await store.refresh([pinned, loose], connectionID: connection, using: wire) {}
        await store.refresh([pinned, loose], connectionID: connection, using: wire) {}
        XCTAssertEqual(wire.calls.map { $0.1["name"]?.text }, ["pinned", "loose", "loose"])

        let bumped = BotProfile(row("pinned", extra: ["has_avatar": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(4)])]))!
        let removed = BotProfile(row("loose", extra: ["has_avatar": .bool(false)]))!
        await store.refresh([bumped, removed], connectionID: connection, using: wire) {}
        XCTAssertEqual(wire.calls.map { $0.1["name"]?.text }, ["pinned", "loose", "loose", "pinned"])
        XCTAssertEqual(Array(store.images(connectionID: connection).keys), ["pinned"])
    }

    func testSameProfileNameOnTwoConnectionsStaysSeparateAndReplacementDropsTheOld() async {
        let store = BotAvatarStore()
        let first = UUID(), second = UUID()
        let profile = BotProfile(row("default", extra: ["has_avatar": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)])]))!
        let small = BotAvatarFixtureWire(); small.assets = ["default": found(png(side: 4))]
        let large = BotAvatarFixtureWire(); large.assets = ["default": found(png(side: 16))]
        await store.refresh([profile], connectionID: first, using: small) {}
        XCTAssertEqual(store.images(connectionID: first)["default"]?.size.width, 4)
        XCTAssertTrue(store.images(connectionID: second).isEmpty)

        // Loading the replacement connection's roster drops the old connection's image.
        await store.refresh([profile], connectionID: second, using: large) {}
        XCTAssertEqual(store.images(connectionID: second)["default"]?.size.width, 16)
        XCTAssertTrue(store.images(connectionID: first).isEmpty)

        store.removeAll(connectionID: second)
        XCTAssertTrue(store.images(connectionID: second).isEmpty)
    }

    func testFailedCallEndsThePassWithoutTouchingEarlierImages() async {
        let store = BotAvatarStore()
        let wire = BotAvatarFixtureWire()
        wire.assets = ["ok": found(png(side: 4))]
        wire.failure = .rejected(-32601)
        let connection = UUID()
        let profiles = ["ok", "unavailable", "never"].map { BotProfile(row($0, extra: ["has_avatar": .bool(true)]))! }
        await store.refresh(profiles, connectionID: connection, using: wire) {}
        XCTAssertEqual(wire.calls.map { $0.1["name"]?.text }, ["ok", "unavailable"])
        XCTAssertEqual(Array(store.images(connectionID: connection).keys), ["ok"])
    }

    func testDecodeBoundsSizeAndRejectsOversizedPayloads() {
        let image = BotAvatarStore.decode(found(png(side: 600)))
        XCTAssertEqual(image?.size.width, CGFloat(BotAvatarStore.maxPixelSize))
        let oversized = "data:image/png;base64," + String(repeating: "A", count: BotAvatarStore.maxPayloadBytes)
        XCTAssertNil(BotAvatarStore.decode(found(oversized)))
        XCTAssertNil(BotAvatarStore.decode(.object(["found": .bool(false)])))
        XCTAssertNil(BotAvatarStore.decode(.object(["found": .bool(true), "data": .string("data:image/png,notbase64")])))
    }
}

/// A tiny solid PNG the server would return for an avatar, as a data URL.
func botAvatarDataURL(side: Int) -> String {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
    return "data:image/png;base64," + image.pngData()!.base64EncodedString()
}

/// Answers `profiles.get_asset` from a scripted table; anything else is unsupported.
@MainActor final class BotAvatarFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var assets: [String: BotJSON] = [:]
    /// Thrown for any Profile missing from `assets`.
    var failure: BotFailure = .transport
    var calls: [(String, [String: BotJSON])] = []
    func connect() async throws {}
    func close() {}
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append((method, params))
        guard method == "profiles.get_asset" else { throw BotFailure.unsupported }
        guard let reply = assets[params["name"]?.text ?? ""] else { throw failure }
        return reply
    }
}
