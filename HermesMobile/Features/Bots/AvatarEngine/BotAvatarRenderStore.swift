import Foundation
import SwiftUI
import UIKit

/// Everything needed to draw one drawn face at rest: the prepared volume, its rest frame and
/// the fitted eyes. Immutable, so any thread may read it.
nonisolated struct BotAvatarFace: Sendable {
    let volume: BotAvatarVolume
    let rest: BotAvatarRestDrawing
    let layout: BotAvatarEyeLayout
    /// A definition whose eyes do not paint last needs body drawn in front of them.
    var hasFrontLayer: Bool {
        rest.frame.shapes[rest.splitIndex...].contains { if case .slice = $0.shape { return true }; return false }
    }
}

/// Builds faces off the main thread, one at a time at utility priority, so opening a roster
/// never fills every core. A hit is a lock and a dictionary read. Bounded by count, and emptied
/// on a memory warning. Definitions that fail validation are remembered, so a bad stored value
/// costs one build and then draws the classic face.
nonisolated final class BotAvatarRenderStore: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let drawn: BotAvatarDefinition
        let depth: Int
        let expression: BotAvatarExpression
    }

    private struct VolumeKey: Hashable { let definition: BotAvatarDefinition; let depth: Int }
    private struct Prepared { let volume: BotAvatarVolume; let rest: BotAvatarRestDrawing }

    static let shared = BotAvatarRenderStore()
    private let limit: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.uzairansar.hermex.avatar-render", qos: .utility)
    private var faces: [Key: BotAvatarFace] = [:]
    private var order: [Key] = []
    private var volumes: [VolumeKey: Prepared] = [:]
    private var failed = Set<Key>()
    private var flights: [Key: Task<BotAvatarFace?, Never>] = [:]
    private var observer: NSObjectProtocol?

    init(limit: Int = 96) {
        self.limit = max(1, limit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.removeAll() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static func key(_ drawn: BotDrawnAvatar, expression: String?) -> Key {
        Key(drawn: drawn.definition, depth: drawn.depth, expression: .resolve(expression))
    }

    /// Main-actor-safe: no engine work.
    func cached(_ key: Key) -> BotAvatarFace? { lock.withLock { faces[key] } }
    func hasFailed(_ key: Key) -> Bool { lock.withLock { failed.contains(key) } }
    var count: Int { lock.withLock { faces.count } }

    /// One build per key however many views ask. Nil means the definition cannot be drawn.
    func face(for key: Key) async -> BotAvatarFace? {
        let task: Task<BotAvatarFace?, Never> = lock.withLock {
            if let hit = faces[key] { return Task { hit } }
            if failed.contains(key) { return Task { nil } }
            if let flight = flights[key] { return flight }
            let flight = Task.detached(priority: .utility) { [self] in
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: self.build(key)) }
                }
            }
            flights[key] = flight
            return flight
        }
        return await task.value
    }

    /// Builds the faces a roster is about to show, so its rows and any synchronous renders hit.
    func prewarm(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            for key in Set(keys) { _ = await face(for: key) }
        }
    }

    func removeAll() {
        lock.withLock { faces.removeAll(); order.removeAll(); volumes.removeAll(); failed.removeAll() }
    }

    private func build(_ key: Key) -> BotAvatarFace? {
        let volumeKey = VolumeKey(definition: key.drawn, depth: key.depth)
        var prepared = lock.withLock { volumes[volumeKey] }
        if prepared == nil, let volume = try? BotAvatarVolume.prepare(key.drawn, depth: Double(key.depth)) {
            prepared = Prepared(volume: volume, rest: BotAvatarRestDrawing(volume: volume))
        }
        let lean = BotAvatarClassic.isClassic(key.drawn) ? BotAvatarClassic.lean : 0
        let face = prepared.map {
            BotAvatarFace(volume: $0.volume, rest: $0.rest,
                          layout: BotAvatarEyeLayout.fit(volume: $0.volume, geometry: key.expression.geometry,
                                                         lean: lean, happy: key.expression.isArc))
        }
        lock.withLock {
            flights.removeValue(forKey: key)
            guard let face, let prepared else { failed.insert(key); return }
            volumes[volumeKey] = prepared
            faces[key] = face; order.append(key)
            while order.count > limit {
                let oldest = order.removeFirst()
                faces.removeValue(forKey: oldest)
                if !order.contains(where: { $0.drawn == oldest.drawn && $0.depth == oldest.depth }) {
                    volumes.removeValue(forKey: VolumeKey(definition: oldest.drawn, depth: oldest.depth))
                }
            }
        }
        return face
    }

    /// One finished bitmap of a face for a synchronous caller (a composer chip, the Live Activity
    /// file). Canvas paints nothing inside `ImageRenderer`, so this draws with Core Graphics.
    /// Nil when the face is not built yet: the caller falls back to the classic face.
    func stillImage(_ key: Key, body: BotAvatarRGB, eyes: BotAvatarRGB, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
        guard let face = cached(key) else { return nil }
        let pixels = Int(ceil(pointSize * scale))
        guard pixels > 0, pixels <= 2048,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 100, y: -CGFloat(pixels) / 100)
        BotAvatarDrawing.draw(frame: BotAvatarFrame.make(volume: face.volume, pose: .rest, layout: face.layout),
                              volume: face.volume, context: context, body: body, ink: eyes)
        return context.makeImage().map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }
}
