import XCTest
import UIKit
@testable import HermesMobile

@MainActor final class AvatarEngineCacheTests: XCTestCase {
    private func rest(_ id: String = "barbell", depth: Double = 6) async throws -> BotAvatarRestDrawing {
        let definition = try XCTUnwrap(BotAvatarCatalog.entries.first { $0.definition.id == id }).definition
        return try await Task.detached { BotAvatarRestDrawing(volume:try BotAvatarVolume.prepare(definition,depth:depth)) }.value
    }
    private func key(_ rest: BotAvatarRestDrawing, color: BotAvatarRGB = .init(255,100,30)) throws -> BotAvatarBodyCache.Key {
        try XCTUnwrap(.init(volume:rest.volume,color:color,appearance:"light",pointSize:40,displayScale:2))
    }
    func testConcurrentMissesShareOneOffMainRender() async throws {
        let rest = try await rest(), key = try key(rest), gate = AvatarRenderGate()
        let started = expectation(description:"render started")
        let cache = BotAvatarBodyCache { key,rest in
            XCTAssertFalse(Thread.isMainThread)
            await gate.started(); started.fulfill(); await gate.wait()
            return BotAvatarBodyCache.render(key:key,rest:rest)
        }
        let requests = (0..<12).map { _ in Task { await cache.value(for:key,rest:rest) } }
        await fulfillment(of:[started],timeout:5)
        await gate.release()
        var images: [BotAvatarBodyBitmap] = []
        for request in requests { let value = await request.value; images.append(try XCTUnwrap(value)) }
        let count = await gate.count
        XCTAssertEqual(count,1)
        XCTAssertTrue(images.allSatisfy { $0.behind === images[0].behind })
        XCTAssertTrue(cache.cached(key)?.behind === images[0].behind)
    }
    func testByteLimitEvictsLeastRecentlyUsedAndRejectsOversize() async throws {
        let rest = try await rest("cat"), firstKey = try key(rest)
        let sample = try XCTUnwrap(BotAvatarBodyCache.render(key:firstKey,rest:rest))
        let cache = BotAvatarBodyCache(byteLimit:sample.byteCost*2,renderer: { _,_ in sample })
        let second = try key(rest,color:.init(10,20,30)), third = try key(rest,color:.init(20,30,40))
        _ = await cache.value(for:firstKey,rest:rest); _ = await cache.value(for:second,rest:rest)
        XCTAssertNotNil(cache.cached(firstKey))
        _ = await cache.value(for:third,rest:rest)
        XCTAssertNotNil(cache.cached(firstKey)); XCTAssertNil(cache.cached(second)); XCTAssertNotNil(cache.cached(third))
        XCTAssertEqual(cache.count,2); XCTAssertLessThanOrEqual(cache.cost,sample.byteCost*2)
        let tiny = BotAvatarBodyCache(byteLimit:sample.byteCost-1,renderer: { _,_ in sample })
        _ = await tiny.value(for:firstKey,rest:rest)
        XCTAssertNil(tiny.cached(firstKey)); XCTAssertEqual(tiny.cost,0)
    }
    func testMemoryWarningClearsEntriesAndPreventsInflightRepopulation() async throws {
        let rest = try await rest(), key = try key(rest), center = NotificationCenter(), gate = AvatarRenderGate()
        let started = expectation(description:"in flight")
        let image = try XCTUnwrap(BotAvatarBodyCache.render(key:key,rest:rest))
        let cache = BotAvatarBodyCache(notificationCenter:center) { _,_ in started.fulfill(); await gate.wait(); return image }
        let request = Task { await cache.value(for:key,rest:rest) }
        await fulfillment(of:[started],timeout:5)
        center.post(name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        await gate.release(); _ = await request.value
        XCTAssertNil(cache.cached(key)); XCTAssertEqual(cache.cost,0)
        let populated = BotAvatarBodyCache(notificationCenter:center,renderer: { _,_ in image })
        _ = await populated.value(for:key,rest:rest); XCTAssertNotNil(populated.cached(key))
        center.post(name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        XCTAssertNil(populated.cached(key)); XCTAssertEqual(populated.cost,0)
    }
    func testRestLayersPreserveForegroundOcclusionAndFlatVectors() async throws {
        for id in ["witch-hat","barbell"] {
            let rest = try await rest(id), key = try key(rest)
            let rendered = await Task.detached { BotAvatarBodyCache.render(key:key,rest:rest) }.value
            let result = try XCTUnwrap(rendered)
            XCTAssertNotNil(result.front,id)
            XCTAssertTrue(rest.flatPaths.isEmpty)
        }
        let flat = try await rest("cat",depth:0), flatKey = try key(flat)
        XCTAssertFalse(flat.flatPaths.isEmpty)
        XCTAssertNil(BotAvatarBodyCache.render(key:flatKey,rest:flat))
    }
}

private actor AvatarRenderGate {
    private var continuations: [CheckedContinuation<Void,Never>] = []
    private var released = false
    var count = 0
    func started() { count += 1 }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { released = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
}
