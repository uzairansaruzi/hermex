import ImageIO
import UIKit

/// Decoded Desktop avatars for the Bots inbox, read through `profiles.get_asset`.
/// Keyed by connection UUID plus Profile name so equal Profile names on two hosts
/// never share an image. Entries exist only for the current connection's roster
/// and drop when the connection is replaced or removed; nothing is written to disk.
@MainActor final class BotAvatarStore {
    static let shared = BotAvatarStore()

    /// Longest decoded edge in pixels: the 48pt row tile at 3x with headroom.
    nonisolated static let maxPixelSize = 192
    /// Largest data URL accepted from the host. The server caps assets at 2 MB before base64.
    nonisolated static let maxPayloadBytes = 3_000_000

    private struct Key: Hashable { let connectionID: UUID; let profile: String }
    private struct Entry { let revision: Int?; let image: UIImage }
    private var entries: [Key: Entry] = [:]

    init() {}

    /// Images for one connection's roster, keyed by Profile name.
    func images(connectionID: UUID) -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for (key, entry) in entries where key.connectionID == connectionID { result[key.profile] = entry.image }
        return result
    }

    func removeAll(connectionID: UUID) {
        entries = entries.filter { $0.key.connectionID != connectionID }
    }

    /// Applies an acknowledged editor write immediately. Keeping the current
    /// look revision is intentional: replacing only the asset does not advance
    /// UI metadata, so a later roster refresh must retain this new thumbnail.
    func setImage(_ image: UIImage?, connectionID: UUID, profile: String, revision: Int?) {
        let key = Key(connectionID: connectionID, profile: profile)
        if let image { entries[key] = Entry(revision: revision, image: image) }
        else { entries.removeValue(forKey: key) }
    }

    /// Brings the store in line with a fresh roster for one connection. Every other
    /// connection's images and rows no longer flagged `has_avatar` drop first, then
    /// `onUpdate` fires so cached images paint before any fetch. Images whose look
    /// revision is unchanged are kept; the rest, including entries without a
    /// revision, are fetched one at a time and `onUpdate` fires after each decode.
    /// The first failed call ends the pass silently: the roster never depends on it.
    func refresh(_ profiles: [BotProfile], connectionID: UUID, using transport: any BotTransport,
                 validateDispatch: (() throws -> Void)? = nil, onUpdate: () -> Void) async {
        let wanted = Set(profiles.filter(\.hasAvatar).map(\.id))
        entries = entries.filter { $0.key.connectionID == connectionID && wanted.contains($0.key.profile) }
        onUpdate()
        for profile in profiles where wanted.contains(profile.id) {
            let key = Key(connectionID: connectionID, profile: profile.id)
            if let revision = entries[key]?.revision, revision == profile.lookRevision { continue }
            guard let reply = try? await transport.call(
                "profiles.get_asset", ["name": .string(profile.id), "asset": .string("avatar")],
                validateDispatch: validateDispatch
            ),
                  !Task.isCancelled else { return }
            let image = await Task.detached(priority: .utility) { Self.decode(reply) }.value
            guard !Task.isCancelled else { return }
            if let image { entries[key] = Entry(revision: profile.lookRevision, image: image) }
            else { entries.removeValue(forKey: key) }
            onUpdate()
        }
    }

    /// Bounds a picked image to the same size the store keeps for fetched assets.
    nonisolated static func thumbnail(_ image: UIImage) -> UIImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > CGFloat(maxPixelSize) else { return image }
        let scale = CGFloat(maxPixelSize) / longest
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Decodes a `profiles.get_asset` reply into a bounded thumbnail. Anything other
    /// than a found, base64 image data URL within the size cap decodes to nil, and a
    /// nil avatar means the row keeps its static shape fallback.
    nonisolated static func decode(_ reply: BotJSON) -> UIImage? {
        guard reply["found"].flag == true, let text = reply["data"].text, text.utf8.count <= maxPayloadBytes,
              text.hasPrefix("data:image/"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(text[text.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
