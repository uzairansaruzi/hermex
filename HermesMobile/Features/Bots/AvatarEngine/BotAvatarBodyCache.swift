import Foundation
import SwiftUI
import UIKit

/// Immutable CGImages may be read across threads; no mutable graphics context escapes rendering.
nonisolated struct BotAvatarBodyBitmap: @unchecked Sendable {
    let behind: CGImage
    let front: CGImage?
    var byteCost: Int { behind.bytesPerRow*behind.height + (front.map { $0.bytesPerRow*$0.height } ?? 0) }
}

/// All mutable state is lock protected. Rendering and awaiting a flight happen outside that lock.
nonisolated final class BotAvatarBodyCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let geometry: BotAvatarDefinition.Body
        let eyes: BotAvatarDefinition.Eyes
        let depth: Double
        let color: BotAvatarRGB
        /// Caller-resolved appearance, so adaptive colors never reuse a bitmap from another appearance.
        let appearance: String
        let pointSize: Double
        let displayScale: Double
        init?(volume: BotAvatarVolume, color: BotAvatarRGB, appearance: String, pointSize: Double, displayScale: Double) {
            guard pointSize.isFinite, displayScale.isFinite, pointSize > 0, displayScale > 0,
                  pointSize*displayScale <= 2048 else { return nil }
            geometry = volume.definition.body; eyes = volume.definition.eyes; depth = volume.depth
            self.color = color; self.appearance = appearance; self.pointSize = pointSize; self.displayScale = displayScale
        }
    }
    typealias Renderer = @Sendable (Key, BotAvatarRestDrawing) async -> BotAvatarBodyBitmap?
    private struct Entry { let value: BotAvatarBodyBitmap; var used: UInt64 }
    private struct Flight { let id: UUID; let task: Task<BotAvatarBodyBitmap?,Never> }
    static let shared = BotAvatarBodyCache()
    private let lock = NSLock()
    private let byteLimit: Int
    private let renderer: Renderer
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var bytes = 0, tick: UInt64 = 0
    init(byteLimit: Int = 24*1024*1024, notificationCenter: NotificationCenter = .default,
         renderer: @escaping Renderer = { key, rest in BotAvatarBodyCache.render(key:key,rest:rest) }) {
        self.byteLimit = max(0,byteLimit); self.center = notificationCenter; self.renderer = renderer
        observer = notificationCenter.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:nil) { [weak self] _ in self?.removeAll() }
    }
    deinit { if let observer { center.removeObserver(observer) }; for flight in flights.values { flight.task.cancel() } }
    /// Synchronous main-actor-safe hit: dictionary lookup only, with no preparation or drawing.
    func cached(_ key: Key) -> BotAvatarBodyBitmap? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            tick &+= 1; entry.used = tick; entries[key] = entry; return entry.value
        }
    }
    var cost: Int { lock.withLock { bytes } }
    var count: Int { lock.withLock { entries.count } }
    /// Shared requests outlive an individual row; cancellation never lets a stale flight repopulate a purge.
    func value(for key: Key, rest: BotAvatarRestDrawing) async -> BotAvatarBodyBitmap? {
        if let hit = cached(key) { return hit }
        let flight: Flight = lock.withLock {
            if let existing = flights[key] { return existing }
            if let hit = entries[key]?.value { return Flight(id:UUID(),task:Task { hit }) }
            let id = UUID(), render = renderer
            let task = Task.detached(priority:.utility) { [weak self] () -> BotAvatarBodyBitmap? in
                let image = await render(key,rest)
                guard !Task.isCancelled else { return nil }
                self?.finish(key:key,id:id,image:image)
                return image
            }
            let flight = Flight(id:id,task:task); flights[key] = flight; return flight
        }
        return await flight.task.value
    }
    private func finish(key: Key, id: UUID, image: BotAvatarBodyBitmap?) {
        lock.withLock {
            guard flights[key]?.id == id else { return }
            flights.removeValue(forKey:key)
            guard let image, image.byteCost <= byteLimit else { return }
            if let prior = entries.removeValue(forKey:key) { bytes -= prior.value.byteCost }
            while bytes + image.byteCost > byteLimit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                bytes -= oldest.value.value.byteCost; entries.removeValue(forKey:oldest.key)
            }
            tick &+= 1; entries[key] = Entry(value:image,used:tick); bytes += image.byteCost
        }
    }
    func removeAll() {
        let tasks = lock.withLock {
            let tasks = flights.values.map(\.task)
            entries.removeAll(); flights.removeAll(); bytes = 0
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }
    static func render(key: Key, rest: BotAvatarRestDrawing) -> BotAvatarBodyBitmap? {
        guard key.depth > 0 else { return nil }
        let pixels = max(1,Int(ceil(key.pointSize*key.displayScale)))
        func image(_ range: Range<Int>) -> CGImage? {
            guard let context = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:0,
                                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x:0,y:Double(pixels)); context.scaleBy(x:Double(pixels)/100,y:-Double(pixels)/100)
            context.concatenate(rest.frame.root.affine); context.setFillColor(BotAvatarDrawing.color(key.color))
            for index in range {
                let item = rest.frame.shapes[index]
                guard let slice = BotAvatarDrawing.slice(item.shape,volume:rest.volume) else { continue }
                context.saveGState(); context.concatenate(item.matrix.affine); context.addPath(slice.path)
                context.drawPath(using:slice.evenOdd ? .eoFill : .fill); context.restoreGState()
            }
            return context.makeImage()
        }
        guard let behind = image(0..<rest.splitIndex) else { return nil }
        let hasFront = rest.frame.shapes[rest.splitIndex...].contains { if case .slice = $0.shape { return true }; return false }
        let front = hasFront ? image(rest.splitIndex..<rest.frame.shapes.count) : nil
        if hasFront && front == nil { return nil }
        return BotAvatarBodyBitmap(behind:behind,front:front)
    }
}

/// Place the eye layer between `.behind` and `.front`. Both share one cache flight.
struct BotAvatarRestBodyLayer: View {
    enum Layer { case behind, front }
    let rest: BotAvatarRestDrawing
    let key: BotAvatarBodyCache.Key
    var layer: Layer = .behind
    var cache: BotAvatarBodyCache = .shared
    @State private var loaded: (BotAvatarBodyCache.Key,BotAvatarBodyBitmap)?
    var body: some View {
        Group {
            if rest.volume.depth == 0 {
                if layer == .behind {
                    Canvas { context,size in
                        context.scaleBy(x:size.width/100,y:size.height/100)
                        for path in rest.flatPaths { context.fill(path,with:.color(Color(cgColor:BotAvatarDrawing.color(key.color)))) }
                    }
                }
            } else if let bitmap = cache.cached(key) ?? (loaded?.0 == key ? loaded?.1 : nil),
                      let image = layer == .behind ? bitmap.behind : bitmap.front {
                Image(decorative:image,scale:key.displayScale).resizable()
            }
        }
        .transaction { $0.animation = nil }
        .task(id:key) {
            guard rest.volume.depth > 0 else { return }
            let bitmap = await cache.value(for:key,rest:rest)
            guard !Task.isCancelled, let bitmap else { return }
            loaded = (key,bitmap)
        }
        .accessibilityHidden(true)
    }
}
