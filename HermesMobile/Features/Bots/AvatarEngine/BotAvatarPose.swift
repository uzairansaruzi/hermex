// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

nonisolated enum BotAvatarMood: String, Codable, Sendable { case idle, thinking, happy }
nonisolated struct BotAvatarGaze: Sendable {
    var x: Double
    var y: Double
    var weight: Double = 1
}
nonisolated struct BotAvatarViewAngle: Sendable {
    var yaw: Double = 0
    var pitch: Double = 0
}
nonisolated indirect enum BotAvatarMoodState: Sendable {
    case mood(BotAvatarMood)
    case blend(from: BotAvatarMoodState, to: BotAvatarMood, progress: Double)
    static func progress(elapsed: TimeInterval) -> Double {
        let t = BotAvatarPose.clamp(elapsed / 0.42, 0, 1)
        return t * t * (3 - 2 * t)
    }
    func settled(share: Double = 1, depth: Int = 0) -> Self {
        guard case .blend(let from, let to, let t) = self else { return self }
        let rest = share * (1 - t)
        if rest < 0.02 || depth >= 3 { return .mood(to) }
        return .blend(from: from.settled(share: rest, depth: depth + 1), to: to, progress: t)
    }
}
nonisolated struct BotAvatarPose: Sendable {
    var yaw = -0.3, pitch = 0.2, roll = 0.0, lift = 0.0, sx = 1.0, sy = 1.0
    var gazeX = 0.0, gazeY = 0.0, blink = 0.0, squintL = 0.0, squintR = 0.0
    var happy = false
    static let rest = Self()
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x.isFinite ? min(hi, max(lo, x)) : lo }
    static func hash(_ text: String) -> UInt32 { text.utf16.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } }
    static func noise(_ seed: UInt32, _ n: UInt32) -> Double {
        var h = seed ^ (n &* 0x9e37_79b1)
        h = (h ^ (h >> 16)) &* 0x85eb_ca6b
        h = (h ^ (h >> 13)) &* 0xc2b2_ae35
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }
    /// Caller owns the clock and blink edges. Idle is always still; active moods preserve upstream phase.
    static func compute(
        seed: UInt32, time: TimeInterval = 0, mood: BotAvatarMoodState = .mood(.idle),
        gaze: BotAvatarGaze? = nil, view: BotAvatarViewAngle = .init(), reducedMotion: Bool = false,
        lid: Double = 1
    ) -> Self {
        func pose(_ state: BotAvatarMoodState, depth: Int = 0) -> Self {
            switch state {
            case .mood(let mood): return base(seed: seed, time: time, mood: mood, gaze: gaze, view: view, reduced: reducedMotion)
            case .blend(let from, let to, let t):
                let target = base(seed: seed, time: time, mood: to, gaze: gaze, view: view, reduced: reducedMotion)
                if reducedMotion || t >= 1 || depth >= 4 { return target }
                return blend(pose(from, depth: depth + 1), target, t)
            }
        }
        var result = pose(mood)
        result.blink = max(result.blink, 1 - clamp(lid, 0, 1))
        return result
    }
    static func blend(_ a: Self, _ b: Self, _ t: Double) -> Self {
        let k = clamp(t, 0, 1)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var p = Self(
            yaw: mix(a.yaw, b.yaw), pitch: mix(a.pitch, b.pitch), roll: mix(a.roll, b.roll), lift: mix(a.lift, b.lift),
            sx: mix(a.sx, b.sx), sy: mix(a.sy, b.sy), gazeX: mix(a.gazeX, b.gazeX), gazeY: mix(a.gazeY, b.gazeY),
            blink: mix(a.blink, b.blink), squintL: mix(a.squintL, b.squintL), squintR: mix(a.squintR, b.squintR), happy: b.happy)
        if a.happy != b.happy {
            p.happy = k < 0.5 ? a.happy : b.happy
            p.blink = max(p.blink, 1 - abs(2 * k - 1))
        }
        return p
    }
    private static func base(seed: UInt32, time: Double, mood: BotAvatarMood, gaze: BotAvatarGaze?, view: BotAvatarViewAngle, reduced: Bool)
        -> Self
    {
        let t = reduced ? 0 : (time.isFinite ? time : 0) + noise(seed, 7) * 10
        func wave(_ period: Double, _ phase: Double = 0) -> Double { reduced ? 0 : sin(2 * .pi * t / period + phase) }
        let given = gaze.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let weight = given.map { clamp($0.weight, 0, 1) } ?? 0
        let sway = 1 - 0.7 * weight
        var p = Self.rest
        if mood == .happy {
            let period = 0.92
            let phase =
                reduced ? 0.5 : (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
            let air = 4 * phase * (1 - phase)
            let land = reduced ? 0 : clamp(1 - min(phase, 1 - phase) / 0.12, 0, 1)
            p.lift = reduced ? 0 : -3.2 * air
            p.sy = 1 - 0.09 * land + (reduced ? 0 : 0.03 * air)
            p.sx = 1 + 0.07 * land - (reduced ? 0 : 0.015 * air)
            p.roll = 4.5 * wave(period * 2)
            p.yaw += 0.1 * wave(period * 2, 0.6)
            p.happy = true
        } else if mood == .thinking {
            p.yaw += 0.12 + 0.05 * sway * wave(7.3)
            p.pitch += 0.08
            p.roll = -5 + 1.4 * wave(4.1)
            p.lift = reduced ? 0 : -0.5 * (1 - cos(2 * .pi * t / 5.2))
            p.gazeX = 0.55 + 0.3 * wave(5.6)
            p.gazeY = -0.8
            p.squintL = 0.22
            p.squintR = 0.32 + 0.1 * wave(3.1)
        }
        if let g = given, weight > 0 {
            let x = clamp(g.x, -1, 1)
            let y = clamp(g.y, -1, 1)
            let share = reduced ? 1.0 : 0.7
            if !p.happy {
                p.gazeX += (x * share - p.gazeX) * weight
                p.gazeY += (y * share - p.gazeY) * weight
            }
            if !reduced {
                p.yaw += weight * (x * 0.32 + 0.3)
                p.pitch += weight * (-y * 0.18 - 0.1)
            }
        }
        if view.yaw.isFinite && view.pitch.isFinite {
            p.yaw += view.yaw
            p.pitch += view.pitch
        }
        return p
    }
}

nonisolated struct BotAvatarFollow: Sendable {
    var x = 0.0, y = 0.0, attention = 0.0
    var gaze: BotAvatarGaze? {
        let a = BotAvatarPose.clamp(attention, 0, 1)
        return a > 0 ? .init(x: x, y: y, weight: a * a * (3 - 2 * a)) : nil
    }
    static func pointer(_ point: CGPoint, in box: CGRect, origin: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> AvatarPoint {
        let reach = max(box.width, box.height, 160)
        let dx = (point.x - box.minX - box.width * origin.x) / reach
        let dy = (point.y - box.minY - box.height * origin.y) / reach
        let m = hypot(dx, dy)
        guard m.isFinite, m >= 1e-9 else { return AvatarPoint(0, 0) }
        let k = tanh(m) / m
        return AvatarPoint(dx * k, dy * k)
    }
    func step(target: AvatarPoint?, dt: TimeInterval, reducedMotion: Bool) -> (state: Self, moving: Bool) {
        let goal = target.map { Self(x: $0.x, y: $0.y, attention: 1) } ?? Self()
        let delta = BotAvatarPose.clamp(dt, 0, 0.1)
        func ease(_ tau: Double) -> Double { reducedMotion ? 1 : 1 - exp(-delta / tau) }
        let k = ease(target == nil ? 0.3 : 0.12)
        let next = Self(x: x + (goal.x - x) * k, y: y + (goal.y - y) * k, attention: attention + (goal.attention - attention) * ease(0.3))
        let moving = abs(goal.x - next.x) > 0.002 || abs(goal.y - next.y) > 0.002 || abs(goal.attention - next.attention) > 0.002
        return (moving ? next : goal, moving)
    }
}
