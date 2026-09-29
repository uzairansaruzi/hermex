import UIKit

/// The process-wide cache of transcript thumbnails: attached images
/// (`MessageBubbleView`) and images the agent links in replies
/// (`TranscriptMediaView`), in webui chats and archived sessions. Bot
/// transcripts render `MessageBubbleView` text-only and never reach it.
///
/// Bounded to 48 MB of decoded pixels and 150 images, and emptied on a memory
/// warning; an evicted image reloads the next time its row appears. Keys carry
/// the server and session namespace, so entries survive a server switch
/// without ever showing under another server. Concurrent requests for one key
/// share a single load, and every image is decoded off the main thread and
/// capped at 512 px before it is stored.
actor TranscriptImageCache {
    static let shared = TranscriptImageCache()

    private let storage: NSCache<NSString, UIImage>
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let notificationCenter: NotificationCenter
    private let memoryWarningObserver: NSObjectProtocol

    /// A fresh instance that applies the limits to `storage`; the app uses
    /// `shared`. Tests pass their own center, so a posted memory warning
    /// reaches only their cache, and may pass storage that records what the
    /// cache stores.
    init(
        notificationCenter: NotificationCenter = .default,
        storage: NSCache<NSString, UIImage> = NSCache()
    ) {
        storage.totalCostLimit = 48 * 1024 * 1024
        storage.countLimit = 150
        self.storage = storage
        // NSCache is thread-safe, which lets the observer clear it on the posting thread.
        nonisolated(unsafe) let observedStorage = storage
        self.notificationCenter = notificationCenter
        // Loads in flight still finish and may land in the emptied cache.
        memoryWarningObserver = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            observedStorage.removeAllObjects()
        }
    }

    deinit {
        notificationCenter.removeObserver(memoryWarningObserver)
    }

    /// The thumbnail for `key`, calling `load` for its bytes only when the
    /// image is neither cached nor already loading. Returns `nil` when there
    /// are no bytes or UIKit can't read them; a failure isn't cached, so the
    /// next request tries again.
    func image(forKey key: String, load: @escaping () async -> Data?) async -> UIImage? {
        if let cached = storage.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        // Detached so neither the load nor the decode runs on this actor.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = await load() else { return nil }
            return Self.thumbnail(from: data)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            storage.setObject(image, forKey: key as NSString, cost: Self.decodedByteCount(of: image))
        }
        return image
    }

    /// Decodes `data` into a display-ready image aspect-fit within 512 px on
    /// its long edge, or `nil` when UIKit can't read or shrink it. A small image
    /// UIKit can't pre-decode (some 16-bit, CMYK, or P3 files on device) comes
    /// back undecoded rather than as nothing. The data is usually already
    /// downsampled; this also caps the full-size bytes a loader falls back to
    /// when downsampling fails. Synchronous: call it off the main thread.
    nonisolated static func thumbnail(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maxPixelSize = CGFloat(ImagePreviewDownsampler.attachmentMaxPixelSize)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > maxPixelSize else {
            return image.preparingForDisplay() ?? image
        }

        let factor = maxPixelSize / longEdge
        let size = CGSize(
            width: max(1, (pixelWidth * factor).rounded()),
            height: max(1, (pixelHeight * factor).rounded())
        )
        return image.preparingThumbnail(of: size)
    }

    /// The memory a decoded image holds; its cost in the cache.
    private nonisolated static func decodedByteCount(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
