import UIKit
import XCTest
@testable import HermesMobile

/// The shared transcript thumbnail cache (#867): one load per key, a clear on
/// memory warning, decoded-byte cost, and the 512 px cap on what it stores.
final class TranscriptImageCacheTests: XCTestCase {
    func testConcurrentRequestsForOneKeyCallTheLoaderOnce() async {
        let cache = TranscriptImageCache(notificationCenter: NotificationCenter())
        let recorder = LoadRecorder()
        let firstLoadStarted = expectation(description: "first load started")
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let data = Self.pngData(width: 64, height: 64)
        // The first load holds until the gate opens, so the second request
        // arrives while it is still in flight.
        let load: () async -> Data? = {
            if await recorder.recordCall() == 1 {
                firstLoadStarted.fulfill()
                for await _ in gate {}
            }
            return data
        }

        let first = Task { await cache.image(forKey: "row", load: load) }
        await fulfillment(of: [firstLoadStarted])
        let second = Task { await cache.image(forKey: "row", load: load) }
        openGate.finish()
        let firstImage = await first.value
        let secondImage = await second.value

        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(firstImage?.cgImage?.width, 64)
        XCTAssertTrue(firstImage === secondImage, "both rows share the one decoded image")
    }

    func testMemoryWarningEmptiesTheCacheSoTheNextRequestLoadsAgain() async {
        let center = NotificationCenter()
        let cache = TranscriptImageCache(notificationCenter: center)
        let recorder = LoadRecorder()
        let data = Self.pngData(width: 64, height: 64)
        let load: () async -> Data? = {
            _ = await recorder.recordCall()
            return data
        }

        _ = await cache.image(forKey: "row", load: load)
        _ = await cache.image(forKey: "row", load: load)
        let callsBeforeWarning = await recorder.callCount
        XCTAssertEqual(callsBeforeWarning, 1, "a cached image is served without loading")

        // The observer runs synchronously on the posting thread, so the cache
        // is already empty when `post` returns.
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let reloaded = await cache.image(forKey: "row", load: load)

        let callsAfterWarning = await recorder.callCount
        XCTAssertEqual(callsAfterWarning, 2)
        XCTAssertEqual(reloaded?.cgImage?.width, 64)
    }

    func testStoredImageCostsItsDecodedBytesUnderTheConfiguredLimits() async throws {
        let cache = TranscriptImageCache(notificationCenter: NotificationCenter())
        let data = Self.pngData(width: 512, height: 512)

        let image = await cache.image(forKey: "row") { data }
        let stored = try XCTUnwrap(image)

        // 512 × 512 pixels × 4 bytes.
        XCTAssertEqual(TranscriptImageCache.decodedByteCount(of: stored), 1_048_576)
        let totalCostLimit = await cache.totalCostLimit
        let countLimit = await cache.countLimit
        XCTAssertEqual(totalCostLimit, 50_331_648, "48 MB")
        XCTAssertEqual(countLimit, 150)
    }

    /// Stands in for the full-size bytes `transcriptMediaThumbnailData` falls
    /// back to when downsampling fails.
    func testOversizedImageIsStoredAspectFitWithin512Pixels() async throws {
        let cache = TranscriptImageCache(notificationCenter: NotificationCenter())
        let data = Self.pngData(width: 2_048, height: 1_024)

        let image = await cache.image(forKey: "row") { data }
        let stored = try XCTUnwrap(image)

        let cgImage = try XCTUnwrap(stored.cgImage)
        XCTAssertEqual(cgImage.width, 512)
        XCTAssertEqual(cgImage.height, 256)
    }

    func testBytesThatAreNotAnImageReturnNilAndAreNotCached() async {
        let cache = TranscriptImageCache(notificationCenter: NotificationCenter())
        let recorder = LoadRecorder()
        let load: () async -> Data? = {
            _ = await recorder.recordCall()
            return Data("not an image".utf8)
        }

        let first = await cache.image(forKey: "row", load: load)
        let second = await cache.image(forKey: "row", load: load)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 2, "a failed load is retried, not cached")
    }

    /// Opaque 8-bit sRGB PNG bytes at exactly `width` × `height` pixels.
    private static func pngData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Counts how many times a test's loader runs.
private actor LoadRecorder {
    private(set) var callCount = 0

    func recordCall() -> Int {
        callCount += 1
        return callCount
    }
}
