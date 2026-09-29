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

    func testStoredImageCostsItsDecodedBytesUnderTheConfiguredLimits() async {
        let storage = CostRecordingStorage()
        let cache = TranscriptImageCache(notificationCenter: NotificationCenter(), storage: storage)
        let data = Self.pngData(width: 512, height: 512)

        let image = await cache.image(forKey: "row") { data }

        XCTAssertEqual(image?.cgImage?.width, 512)
        // 512 × 512 pixels × 4 bytes, handed to NSCache as the entry's cost.
        XCTAssertEqual(storage.recordedCosts, [1_048_576])
        XCTAssertEqual(storage.totalCostLimit, 50_331_648, "48 MB")
        XCTAssertEqual(storage.countLimit, 150)
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

    /// Formats `preparingForDisplay()` can refuse (16-bit gray PNG, CMYK JPEG)
    /// still show: undecoded, and already within the 512 px cap.
    func testSmallImagesInUnusualFormatsStillShow() throws {
        let gray16 = try Self.encodedData(
            width: 64, height: 48, bitsPerComponent: 16,
            colorSpace: CGColorSpaceCreateDeviceGray(), type: "public.png"
        )
        let cmyk = try Self.encodedData(
            width: 64, height: 48, bitsPerComponent: 8,
            colorSpace: CGColorSpaceCreateDeviceCMYK(), type: "public.jpeg"
        )

        for (name, data) in [("16-bit gray PNG", gray16), ("CMYK JPEG", cmyk)] {
            let image = try XCTUnwrap(TranscriptImageCache.thumbnail(from: data), name)
            XCTAssertEqual(image.size.width * image.scale, 64, name)
            XCTAssertEqual(image.size.height * image.scale, 48, name)
        }
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

    /// A filled `width` × `height` image drawn in `colorSpace` and encoded as `type`.
    private static func encodedData(
        width: Int, height: Int, bitsPerComponent: Int, colorSpace: CGColorSpace, type: String
    ) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let components = [CGFloat](repeating: 0.5, count: colorSpace.numberOfComponents) + [1]
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: components)))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
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

/// Records the cost the cache hands `NSCache` for each stored image.
private final class CostRecordingStorage: NSCache<NSString, UIImage> {
    private(set) var recordedCosts: [Int] = []

    override func setObject(_ obj: UIImage, forKey key: NSString, cost g: Int) {
        recordedCosts.append(g)
        super.setObject(obj, forKey: key, cost: g)
    }
}
