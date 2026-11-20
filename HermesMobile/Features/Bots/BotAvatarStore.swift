import ImageIO
import UniformTypeIdentifiers
import UIKit

@MainActor final class BotAvatarStore {
    static let shared = BotAvatarStore()

    nonisolated static let maxPixelSize = 192
    nonisolated static let maxPayloadBytes = 3_000_000

    private struct Key: Hashable { let connectionID: UUID; let profile: String }
    private struct Entry { let revision: Int?; let image: UIImage? }
    private var entries: [Key: Entry] = [:]

    init() {}

    func images(connectionID: UUID) -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for (key, entry) in entries where key.connectionID == connectionID { result[key.profile] = entry.image }
        return result
    }

    func removeAll(connectionID: UUID) {
        entries = entries.filter { $0.key.connectionID != connectionID }
    }

    func setImage(_ image: UIImage?, connectionID: UUID, profile: String, revision: Int?) {
        let key = Key(connectionID: connectionID, profile: profile)
        if let image { entries[key] = Entry(revision: revision, image: image) }
        else { entries.removeValue(forKey: key) }
    }

    func refresh(_ profiles: [BotProfile], connectionID: UUID, using transport: any BotTransport,
                 validateDispatch: (() throws -> Void)? = nil, onUpdate: () -> Void) async {
        let wanted = Set(profiles.filter(\.hasAvatar).map(\.id))
        entries = entries.filter { $0.key.connectionID == connectionID && wanted.contains($0.key.profile) }
        onUpdate()
        for profile in profiles where wanted.contains(profile.id) {
            let key = Key(connectionID: connectionID, profile: profile.id)
            if let revision = entries[key]?.revision, revision == profile.lookRevision { continue }
            guard let reply = try? await transport.call(.profilesGetAsset(name: profile.id), validateDispatch: validateDispatch),
                  !Task.isCancelled else { return }
            let photo = profile.isPhoto
            let asset = await Task.detached(priority: .utility) { Self.asset(reply, photo: photo) }.value
            guard !Task.isCancelled else { return }
            if let asset { entries[key] = Entry(revision: profile.lookRevision, image: asset.image) }
            else { entries.removeValue(forKey: key) }
            onUpdate()
        }
    }

    nonisolated static func thumbnail(_ image: UIImage) -> UIImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > CGFloat(maxPixelSize) else { return image }
        let scale = CGFloat(maxPixelSize) / longest
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    enum Asset {
        case image(UIImage), faceCopy
        var image: UIImage? { if case .image(let image) = self { image } else { nil } }
    }

    nonisolated static func decode(_ reply: BotJSON, photo: Bool) -> UIImage? { asset(reply, photo: photo)?.image }

    nonisolated static func asset(_ reply: BotJSON, photo: Bool) -> Asset? {
        guard reply["found"].flag == true, let text = reply["data"].text, text.utf8.count <= maxPayloadBytes,
              text.hasPrefix("data:image/"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(text[text.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if !photo, isDesktopFaceCopy(source) { return .faceCopy }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .image(UIImage(cgImage: thumbnail))
    }

    private nonisolated static func isDesktopFaceCopy(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyPixelWidth] as? Int == 160 && properties[kCGImagePropertyPixelHeight] as? Int == 160
    }
}
