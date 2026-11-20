import UIKit

actor TranscriptImageCache {
    static let shared = TranscriptImageCache()

    private let storage: NSCache<NSString, UIImage>
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let notificationCenter: NotificationCenter
    private let memoryWarningObserver: NSObjectProtocol

    init(
        notificationCenter: NotificationCenter = .default,
        storage: NSCache<NSString, UIImage> = NSCache()
    ) {
        storage.totalCostLimit = 48 * 1024 * 1024
        storage.countLimit = 150
        self.storage = storage
        nonisolated(unsafe) let observedStorage = storage
        self.notificationCenter = notificationCenter
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

    func image(forKey key: String, load: @escaping () async -> Data?) async -> UIImage? {
        if let cached = storage.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

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

    private nonisolated static func decodedByteCount(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
