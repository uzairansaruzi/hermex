import SwiftUI

/// The looks a Thinking slider can wear, chosen in Settings > Appearance. A look draws on a `Canvas`
/// every frame while on screen, so these are the one exception to the no-repainting rule: the owner
/// chose it for this control (#1550). Reduce Motion stills them. New cases keep their raw value, which
/// is stored on the device, and a value this build doesn't know falls back to `defaultLook`.
enum ThinkingSliderLook: String, CaseIterable, Identifiable {
    case slipstream, dataPackets, forge, eventHorizon, synapse, oscilloscope, equalizer, aurora
    case silk, vectorDrive, pressureWave, induction, foldedLight, relay, liquidCore

    static let storageKey = "appearance.thinkingSliderLook"
    static let defaultLook = ThinkingSliderLook.slipstream

    var id: Self { self }

    /// A proper name, like an app icon's, so it reads the same in every language.
    var name: String {
        switch self {
        case .slipstream: "Slipstream"
        case .dataPackets: "Data Packets"
        case .forge: "Forge"
        case .eventHorizon: "Event Horizon"
        case .synapse: "Synapse"
        case .oscilloscope: "Oscilloscope"
        case .equalizer: "Equalizer"
        case .aurora: "Aurora"
        case .silk: "Silk"
        case .vectorDrive: "Vector Drive"
        case .pressureWave: "Pressure Wave"
        case .induction: "Induction"
        case .foldedLight: "Folded Light"
        case .relay: "Relay"
        case .liquidCore: "Liquid Core"
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .dataPackets, .equalizer: 14
        default: ThinkingSliderMetrics.height / 2
        }
    }

    func drawTrack(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        switch self {
        case .slipstream: Self.drawSlipstream(&context, frame, store)
        case .dataPackets: Self.drawDataPackets(&context, frame, store)
        case .forge: Self.drawForge(&context, frame, store)
        case .eventHorizon: Self.drawEventHorizon(&context, frame, store)
        case .synapse: Self.drawSynapse(&context, frame, store)
        case .oscilloscope: Self.drawOscilloscope(&context, frame, store)
        case .equalizer: Self.drawEqualizer(&context, frame, store)
        case .aurora: Self.drawAurora(&context, frame, store)
        case .silk: Self.drawSilk(&context, frame, store)
        case .vectorDrive: Self.drawVectorDrive(&context, frame, store)
        case .pressureWave: Self.drawPressureWave(&context, frame, store)
        case .induction: Self.drawInduction(&context, frame, store)
        case .foldedLight: Self.drawFoldedLight(&context, frame, store)
        case .relay: Self.drawRelay(&context, frame, store)
        case .liquidCore: Self.drawLiquidCore(&context, frame, store)
        }
    }

    func drawThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        switch self {
        case .dataPackets: Self.drawPacketsThumb(&context, frame)
        case .eventHorizon: Self.drawHorizonThumb(&context, frame)
        case .equalizer: Self.drawEqualizerThumb(&context, frame)
        case .vectorDrive: Self.drawVectorThumb(&context, frame)
        case .pressureWave: Self.drawPressureThumb(&context, frame)
        case .foldedLight: Self.drawFoldedThumb(&context, frame)
        case .relay: Self.drawRelayThumb(&context, frame)
        default: Self.drawRoundThumb(&context, frame)
        }
    }
}

enum ThinkingSliderMetrics {
    static let height: CGFloat = 56
    /// How far the thumb's center stays from each end of the track.
    static let inset: CGFloat = 24
}

/// One frame's inputs. `level` runs 0 to 1 along the track, eased toward the selection; `thumbX` is
/// the thumb's center.
struct ThinkingSliderFrame {
    let width: Double
    let height: Double
    let time: Double
    let delta: Double
    let level: Double
    let thumbX: Double
}

/// A look's state between frames. A `Canvas` draws from the last frame's state, so this is a plain
/// class outside SwiftUI's invalidation: updating it never redraws anything by itself.
final class ThinkingSliderStore {
    struct Particle {
        var x = 0.0, y = 0.0, speed = 0.0, life = 0.0
    }

    struct Pulse {
        var edge: Int, progress: Double
    }

    private(set) var level: Double?
    private var lastTime: Double?
    var phase = 0.0
    var particles: [Particle] = []
    var fired: [Double] = []
    var pulses: [Pulse] = []
    var accumulator = 0.0

    /// The frame at `time`, with the level eased toward `target`. Motion advances `phase` itself;
    /// a still timeline (Reduce Motion) snaps to the target with no time passing.
    func advance(time: Double, target: Double, followsFinger: Bool, size: CGSize, isStill: Bool) -> ThinkingSliderFrame {
        let delta = isStill ? 0 : min(max(time - (lastTime ?? time), 0), 0.05)
        lastTime = time
        let response = followsFinger ? 0.5 : 0.22
        let eased = level.map { $0 + (target - $0) * (1 - pow(1 - response, delta * 60)) } ?? target
        let settled = isStill ? target : eased
        level = settled
        let span = max(size.width - ThinkingSliderMetrics.inset * 2, 1)
        return ThinkingSliderFrame(
            width: size.width, height: size.height, time: isStill ? 0 : time, delta: delta,
            level: settled, thumbX: ThinkingSliderMetrics.inset + settled * span
        )
    }
}

/// Small, stable random numbers: the same seed draws the same thing every frame.
func thinkingRandom(_ seed: Double) -> Double {
    let value = sin(seed * 127.1 + 311.7) * 43758.5453
    return value - floor(value)
}

func thinkingLerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    from + (to - from) * amount
}

/// Cool blue through violet and pink to hot orange.
func thinkingHeat(_ level: Double, opacity: Double = 1) -> Color {
    let stops: [(Double, Double, Double)] = [(86, 140, 255), (168, 96, 255), (255, 92, 170), (255, 150, 70)]
    let position = min(max(level, 0), 0.999) * Double(stops.count - 1)
    let index = Int(position), mix = position - Double(index)
    let (from, to) = (stops[index], stops[index + 1])
    return Color(
        red: thinkingLerp(from.0, to.0, mix) / 255,
        green: thinkingLerp(from.1, to.1, mix) / 255,
        blue: thinkingLerp(from.2, to.2, mix) / 255,
        opacity: opacity
    )
}

extension Color {
    /// `0xRRGGBB`, for the looks' fixed palettes.
    init(thinkingHex hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity
        )
    }
}

extension GraphicsContext {
    mutating func fillThinkingTrack(_ frame: ThinkingSliderFrame, _ hex: UInt32) {
        fill(Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)), with: .color(Color(thinkingHex: hex)))
    }
}

/// Filling every dot or pixel with its own opacity would be hundreds of draws a frame. Grouping them
/// into a few opacities makes it a handful, with no visible difference at this size.
struct ThinkingOpacityBuckets {
    private(set) var paths: [Path]

    init(count: Int) { paths = Array(repeating: Path(), count: count) }

    mutating func append(opacity: Double, _ add: (inout Path) -> Void) {
        let index = min(max(Int(opacity * Double(paths.count)), 0), paths.count - 1)
        add(&paths[index])
    }

    func opacity(at index: Int) -> Double { (Double(index) + 0.5) / Double(paths.count) }
}

// MARK: - Particles and pixels

extension ThinkingSliderLook {
    /// Rows of dots flow left to right and stretch into streaks as they speed up.
    fileprivate static func drawSlipstream(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        store.phase += frame.delta * (6 + 300 * frame.level * frame.level)
        context.fillThinkingTrack(frame, 0x101014)
        let rows = 7, gap = 13.0
        let length = min(16, 34 * frame.level * frame.level)
        var lit = ThinkingOpacityBuckets(count: 6), ahead = Path()
        for row in 0..<rows {
            let y = (Double(row) + 0.5) * frame.height / Double(rows)
            let depth = 0.55 + 0.45 * thinkingRandom(Double(row) + 1)
            let offset = thinkingRandom(Double(row) + 9) * gap
            var x = 0.0
            while x <= frame.width + gap {
                let position = (x + store.phase * depth + offset).truncatingRemainder(dividingBy: frame.width + gap) - gap / 2
                let streak = 2 + length * depth
                if position < frame.thumbX {
                    let opacity = 0.35 + 0.65 * min(1, max(position, 0) / max(frame.thumbX, 1))
                    lit.append(opacity: opacity) { path in
                        path.move(to: CGPoint(x: position - streak, y: y))
                        path.addLine(to: CGPoint(x: position, y: y))
                    }
                } else {
                    ahead.move(to: CGPoint(x: position - streak, y: y))
                    ahead.addLine(to: CGPoint(x: position, y: y))
                }
                x += gap
            }
        }
        let line = StrokeStyle(lineWidth: 2, lineCap: .round)
        context.stroke(ahead, with: .color(.white.opacity(0.09)), style: line)
        for index in lit.paths.indices {
            context.stroke(lit.paths[index], with: .color(thinkingHeat(frame.level * 0.5, opacity: lit.opacity(at: index))), style: line)
        }
    }

    /// A pixel grid with bright packets racing through it toward the thumb.
    fileprivate static func drawDataPackets(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let step = 7.0, cell = 5.0
        let columns = Int((frame.width / step).rounded(.up)), rows = Int(frame.height / step)
        let top = (frame.height - Double(rows) * step + 2) / 2
        context.fillThinkingTrack(frame, 0x121116)

        let wanted = 2 + Int((16 * frame.level).rounded())
        while store.particles.count < wanted {
            let seed = Double(store.particles.count)
            store.particles.append(.init(
                x: -thinkingRandom(seed) * frame.width, y: floor(thinkingRandom(seed + 3) * Double(rows)),
                speed: 0.5 + thinkingRandom(seed + 7)
            ))
        }
        if store.particles.count > wanted { store.particles.removeLast(store.particles.count - wanted) }
        for index in store.particles.indices {
            store.particles[index].x += frame.delta * store.particles[index].speed * (10 + 420 * frame.level * frame.level)
            if store.particles[index].x > frame.thumbX {
                store.particles[index].x = -thinkingRandom(frame.time + Double(index)) * 40
                store.particles[index].y = floor(thinkingRandom(frame.time * 3 + Double(index)) * Double(rows))
            }
        }

        var lit = ThinkingOpacityBuckets(count: 8)
        let flickerTick = floor(frame.time * (1 + 14 * frame.level))
        for row in 0..<rows {
            let packets = store.particles.filter { Int($0.y) == row }
            for column in 0..<columns {
                let x = Double(column) * step
                let isLit = x < frame.thumbX
                var opacity = isLit ? 0.08 + 0.42 * (x / max(frame.thumbX, 1)) : 0.05
                if isLit { opacity += thinkingRandom(Double(column * 13 + row * 7) + flickerTick) * 0.22 * frame.level }
                for packet in packets {
                    let behind = packet.x - x
                    if behind >= 0, behind < 34 { opacity = max(opacity, 1 - behind / 34) }
                }
                lit.append(opacity: opacity) { $0.addRect(CGRect(x: x, y: top + Double(row) * step, width: cell, height: cell)) }
            }
        }
        for index in lit.paths.indices {
            context.fill(lit.paths[index], with: .color(Color(thinkingHex: 0xC4B2FF, opacity: lit.opacity(at: index))))
        }
    }

    fileprivate static func drawPacketsThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let center = CGPoint(x: frame.thumbX, y: frame.height / 2)
        let glow = 26 + 16 * frame.level
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(thinkingHex: 0xC4B2FF, opacity: 0.7), .clear]),
                center: center, startRadius: 8, endRadius: glow
            )
        )
        let thumb = Path(roundedRect: CGRect(x: center.x - 16, y: center.y - 22, width: 32, height: 44), cornerRadius: 9)
        context.fill(thumb, with: .color(Color(thinkingHex: 0xEFEAFF)))
    }

    /// A bar heats from dark iron to copper to white gold, with embers that rise faster as it heats.
    fileprivate static func drawForge(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level
        context.fillThinkingTrack(frame, 0x17120F)
        let lit = CGRect(x: 0, y: 0, width: frame.thumbX, height: frame.height)
        context.fill(Path(lit), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(thinkingHex: 0x3A2015), location: 0),
                .init(color: Color(red: thinkingLerp(90, 214, level) / 255, green: thinkingLerp(50, 112, level) / 255, blue: 46 / 255), location: 0.6),
                .init(color: Color(red: 1, green: thinkingLerp(120, 214, level) / 255, blue: thinkingLerp(60, 150, level) / 255), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: frame.thumbX, y: 0)
        ))
        let center = CGPoint(x: frame.thumbX, y: frame.height / 2)
        let radius = 40 + 60 * level
        let glow = 0.1 + 0.25 * level + 0.08 * sin(frame.time * (1 + 6 * level))
        context.fill(
            Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.9, blue: 0.7, opacity: glow), Color(red: 1, green: 0.7, blue: 0.35, opacity: 0)]),
                center: center, startRadius: 2, endRadius: radius
            )
        )
        let wanted = 4 + Int((56 * level).rounded())
        while store.particles.count < wanted {
            store.particles.append(.init(
                x: .random(in: 0...max(frame.thumbX, 1)), y: frame.height + .random(in: 0...frame.height),
                speed: 0.4 + .random(in: 0...1), life: .random(in: 0...1)
            ))
        }
        if store.particles.count > wanted { store.particles.removeLast(store.particles.count - wanted) }
        var embers = ThinkingOpacityBuckets(count: 5)
        for index in store.particles.indices {
            var ember = store.particles[index]
            ember.y -= frame.delta * ember.speed * (8 + 90 * level)
            ember.x += frame.delta * (6 + 60 * level * level)
            if ember.y < -2 || ember.x > frame.thumbX {
                ember.x = .random(in: 0...max(frame.thumbX, 1))
                ember.y = frame.height + 2
                ember.life = .random(in: 0...1)
            }
            store.particles[index] = ember
            let size = 0.7 + ember.life * 1.1
            let opacity = (0.35 + 0.65 * ember.life) * min(1, ember.y / frame.height + 0.3)
            embers.append(opacity: opacity) {
                $0.addEllipse(in: CGRect(x: ember.x - size, y: ember.y - size, width: size * 2, height: size * 2))
            }
        }
        for index in embers.paths.indices {
            context.fill(embers.paths[index], with: .color(Color(red: 1, green: 0.94, blue: 0.82, opacity: embers.opacity(at: index))))
        }
    }

    /// Stars are pulled across the track and fall into the thumb, curving in as they accelerate.
    fileprivate static func drawEventHorizon(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level
        context.fillThinkingTrack(frame, 0x07080F)
        let wanted = 14 + Int((90 * level).rounded())
        while store.particles.count < wanted {
            store.particles.append(.init(x: .random(in: 0...1), y: .random(in: 0...1), speed: 0.5 + .random(in: 0...1)))
        }
        if store.particles.count > wanted { store.particles.removeLast(store.particles.count - wanted) }

        for index in store.particles.indices {
            var star = store.particles[index]
            star.x += frame.delta * star.speed * (0.03 + 1.3 * level * level) * (0.4 + star.x)
            if star.x >= 1 { star.x = 0; star.y = .random(in: 0...1) }
            store.particles[index] = star
            let back = max(0.005, 0.02 + 0.13 * level * level) * (0.4 + star.x)
            let tail = max(0, star.x - back)
            var path = Path()
            path.move(to: CGPoint(
                x: frame.thumbX * tail,
                y: thinkingLerp(star.y * frame.height, frame.height / 2, tail * tail)
            ))
            path.addLine(to: CGPoint(
                x: frame.thumbX * star.x + 0.1,
                y: thinkingLerp(star.y * frame.height, frame.height / 2, star.x * star.x)
            ))
            context.stroke(
                path, with: .color(thinkingHeat(star.x * (0.3 + 0.7 * level), opacity: 0.25 + 0.75 * star.x)),
                style: StrokeStyle(lineWidth: 1 + star.x, lineCap: .round)
            )
        }
        var far = Path()
        for index in 0..<26 {
            let seed = Double(index)
            let x = frame.thumbX + thinkingRandom(seed) * max(0, frame.width - frame.thumbX)
            far.addRect(CGRect(x: x, y: thinkingRandom(seed + 8) * frame.height, width: 1.2, height: 1.2))
        }
        context.fill(far, with: .color(.white.opacity(0.1)))
    }

    fileprivate static func drawHorizonThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let center = CGPoint(x: frame.thumbX, y: frame.height / 2)
        let pulse = 0.5 + 0.5 * sin(frame.time * (1 + 9 * frame.level))
        let halo = Path(ellipseIn: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
        context.fill(halo, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.5 + 0.5 * frame.level), location: 0),
                .init(color: thinkingHeat(frame.level, opacity: 0.25 + 0.45 * frame.level * (0.7 + 0.3 * pulse)), location: 0.4),
                .init(color: .clear, location: 1)
            ]),
            center: center, startRadius: 2, endRadius: 30
        ))
        let core = Path(ellipseIn: CGRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34))
        context.fill(core, with: .color(Color(thinkingHex: 0x050509)))
        context.stroke(core, with: .color(.white.opacity(0.92)), lineWidth: 2)
    }

    /// A small neural network: nodes fire and pulses travel between them.
    fileprivate static func drawSynapse(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level, count = 30
        context.fillThinkingTrack(frame, 0x0D0F14)
        let nodes = (0..<count).map { index -> CGPoint in
            let seed = Double(index)
            return CGPoint(
                x: (seed + 0.5 + (thinkingRandom(seed) - 0.5)) / Double(count) * frame.width,
                y: 7 + thinkingRandom(seed + 40) * (frame.height - 14)
            )
        }
        let edges: [(Int, Int)] = (0..<count).flatMap { from in
            ((from + 1)...(from + 3)).filter { $0 < count }.map { (from, $0) }
        }
        if store.fired.count != count { store.fired = Array(repeating: 0, count: count) }

        var litEdges = Path(), darkEdges = Path()
        for (from, to) in edges {
            let lit = nodes[to].x < frame.thumbX
            if lit { litEdges.move(to: nodes[from]); litEdges.addLine(to: nodes[to]) } else {
                darkEdges.move(to: nodes[from]); darkEdges.addLine(to: nodes[to])
            }
        }
        context.stroke(darkEdges, with: .color(.white.opacity(0.05)), lineWidth: 1)
        context.stroke(litEdges, with: .color(Color(red: 0.47, green: 0.75, blue: 1, opacity: 0.14 + 0.2 * level)), lineWidth: 1)

        store.accumulator += frame.delta * (0.2 + 34 * level * level)
        let live = edges.indices.filter { nodes[edges[$0].1].x < frame.thumbX }
        while store.accumulator > 1, store.pulses.count < 60, !live.isEmpty {
            store.accumulator -= 1
            store.pulses.append(.init(edge: live[Int.random(in: 0..<live.count)], progress: 0))
        }
        store.accumulator = min(store.accumulator, 2)

        var traveling = Path()
        store.pulses = store.pulses.compactMap { pulse in
            var pulse = pulse
            pulse.progress += frame.delta * (1.2 + 6 * level)
            let (from, to) = edges[pulse.edge]
            if pulse.progress >= 1 {
                store.fired[to] = 1
                return nil
            }
            traveling.addEllipse(in: CGRect(
                x: thinkingLerp(nodes[from].x, nodes[to].x, pulse.progress) - 1.6,
                y: thinkingLerp(nodes[from].y, nodes[to].y, pulse.progress) - 1.6,
                width: 3.2, height: 3.2
            ))
            return pulse
        }
        context.fill(traveling, with: .color(Color(red: 0.75, green: 0.92, blue: 1, opacity: 0.95)))

        for index in nodes.indices {
            store.fired[index] = max(0, store.fired[index] - frame.delta * 2.6)
            let fire = store.fired[index], node = nodes[index], radius = 1.8 + 2.6 * fire
            let color: Color = node.x >= frame.thumbX ? .white.opacity(0.14)
                : fire > 0.05 ? Color(red: 0.82, green: 0.94, blue: 1, opacity: 0.5 + 0.5 * fire)
                : Color(red: 0.47, green: 0.75, blue: 1, opacity: 0.55)
            context.fill(
                Path(ellipseIn: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color)
            )
        }
    }

    /// Layered waves travel left to right: flat at the bottom of the ladder, then taller and busier.
    fileprivate static func drawOscilloscope(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level
        store.phase += frame.delta * (0.6 + 15 * level)
        context.fillThinkingTrack(frame, 0x0B0C10)
        for layer in stride(from: 2, through: 0, by: -1) {
            let depth = Double(layer)
            var path = Path(), x = 0.0
            while x <= frame.thumbX {
                let envelope = sin(min(1, x / max(frame.thumbX, 1)) * .pi * 0.5)
                let wave = sin(x * (0.022 + 0.05 * level) * (1 + depth * 0.42) - store.phase * (1 + depth * 0.3))
                let y = frame.height / 2 - envelope * (1 + 21 * level) * (1 - depth * 0.26) * wave
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 2
            }
            let color = thinkingHeat(min(1, level + depth * 0.08), opacity: layer == 0 ? 1 : 0.4 - depth * 0.08)
            if layer == 0 {
                context.stroke(path, with: .color(thinkingHeat(level, opacity: 0.18 + 0.2 * level)), lineWidth: 5 + 4 * level)
            }
            context.stroke(path, with: .color(color), lineWidth: layer == 0 ? 2 : 1.4)
        }
        var rest = Path()
        rest.move(to: CGPoint(x: frame.thumbX, y: frame.height / 2))
        rest.addLine(to: CGPoint(x: frame.width, y: frame.height / 2))
        context.stroke(rest, with: .color(.white.opacity(0.12)), lineWidth: 1)
    }

    /// Bars dance like a music visualizer and rise toward the thumb.
    fileprivate static func drawEqualizer(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level, bars = 42
        store.phase += frame.delta * (0.5 + 11 * level)
        context.fillThinkingTrack(frame, 0x0E0E12)
        let width = frame.width / Double(bars)
        for index in 0..<bars {
            let seed = Double(index), x = seed * width
            let lit = x + width / 2 < frame.thumbX
            let envelope = lit ? 0.2 + 0.8 * (x / max(frame.thumbX, 1)) : 0
            let noise = 0.5 + 0.5 * sin(store.phase * (1 + thinkingRandom(seed)) + seed * 0.7) * sin(store.phase * 0.6 + seed * 0.19)
            let height = lit ? 4 + (frame.height - 10) * envelope * (0.18 + 0.82 * level) * (0.35 + 0.65 * noise) : 3
            let rect = CGRect(x: x + 1, y: frame.height - height - 4, width: width - 2, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2),
                with: .color(lit ? thinkingHeat(min(1, height / frame.height * (0.3 + level))) : .white.opacity(0.13))
            )
        }
    }

    fileprivate static func drawEqualizerThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let rect = CGRect(x: frame.thumbX - 5, y: 4, width: 10, height: frame.height - 8)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.white))
    }

    /// Soft ribbons of colored light drift through the bar.
    fileprivate static func drawAurora(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let level = frame.level
        store.phase += frame.delta * (0.15 + 5 * level)
        context.fillThinkingTrack(frame, 0x0A0B12)
        var light = context
        light.clip(to: Path(CGRect(x: 0, y: 0, width: frame.thumbX, height: frame.height)))
        light.blendMode = .plusLighter
        for ribbon in 0..<4 {
            let depth = Double(ribbon)
            let color = thinkingHeat(min(1, level * 0.8 + depth * 0.09))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: frame.height))
            var x = 0.0
            while x <= frame.thumbX + 6 {
                let y = frame.height * 0.5
                    + (9 + 12 * level) * sin(x * 0.018 * (1 + depth * 0.35) - store.phase * (1 + depth * 0.22) + depth * 1.7)
                    + 4 * sin(x * 0.05 - store.phase * 1.3 + depth)
                path.addLine(to: CGPoint(x: x, y: y - (13 + 6 * depth)))
                x += 6
            }
            path.addLine(to: CGPoint(x: frame.thumbX + 6, y: frame.height))
            path.closeSubpath()
            light.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color.opacity(0.22 + 0.34 * level), location: 0.5),
                    .init(color: color.opacity(0), location: 1)
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: frame.height)
            ))
        }
    }

    /// The plain white thumb most looks use.
    fileprivate static func drawRoundThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let center = CGPoint(x: frame.thumbX, y: frame.height / 2)
        let shadow = Path(ellipseIn: CGRect(x: center.x - 24, y: center.y - 23, width: 48, height: 48))
        context.fill(shadow, with: .radialGradient(
            Gradient(colors: [.black.opacity(0.4), .clear]), center: center, startRadius: 18, endRadius: 24
        ))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 21, y: center.y - 21, width: 42, height: 42)), with: .color(.white))
    }
}
