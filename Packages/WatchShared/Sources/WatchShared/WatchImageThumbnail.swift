import Foundation
import ImageIO

/// Wrist-safe JPEG thumbs. `sendMessage` is ~65 KB after JSON/base64, so face
/// thumbs stay under 20 KB. Send-side photos can be larger — they use `transferFile`.
public enum WatchImageThumbnail: Sendable {
    public static let watchFaceMaxPixelSize = 200
    public static let sendMaxPixelSize = 1_024
    public static let watchFaceMaxBytes = 20_000
    public static let sendMaxBytes = 1_200_000

    public static func jpeg(
        from data: Data,
        maxPixelSize: Int = watchFaceMaxPixelSize,
        maxBytes: Int = watchFaceMaxBytes
    ) -> Data? {
        guard !data.isEmpty, maxPixelSize > 0, maxBytes > 0 else { return nil }
        var pixelSize = maxPixelSize
        for quality in [0.62, 0.45, 0.32] as [CGFloat] {
            guard let encoded = encode(data, maxPixelSize: pixelSize, quality: quality) else { continue }
            if encoded.count <= maxBytes { return encoded }
            pixelSize = max(80, pixelSize * 2 / 3)
        }
        if let last = encode(data, maxPixelSize: 80, quality: 0.28), last.count <= maxBytes {
            return last
        }
        return nil
    }

    private static func encode(_ data: Data, maxPixelSize: Int, quality: CGFloat) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
