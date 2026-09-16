import SwiftUI

/// How a drawn bot face moves. `.still` is one frozen frame, used by the picker
/// tiles, Reduce Motion and the extensions. `.idle` blinks on a sparse schedule. `.working`
/// is Desktop's lean-and-sway pose, only for the open bot while its turn is live.
enum BotFaceMotion: Equatable, Sendable {
    case still, idle, working

    /// Reduce Motion collapses every mode to a still face.
    func honoring(reduceMotion: Bool) -> BotFaceMotion { reduceMotion ? .still : self }
}

/// One frame of a face: gaze offset as a fraction of the mark size, head roll in
/// degrees and the lid factor applied to eye height (1 open, 0.06 shut).
struct BotFacePose: Equatable, Sendable {
    var gazeX = 0.0
    var gazeY = 0.0
    var roll = 0.0
    var lid = 1.0
    /// Vertical lift as a fraction of the mark size (positive is up) and the
    /// squash-and-stretch scale, used only by the playful bits.
    var lift = 0.0
    var scaleX = 1.0
    var scaleY = 1.0

    static let rest = BotFacePose()
    static let blink = BotFacePose(lid: 0.06)

    /// Desktop's `work` pose (`avatar.tsx` facePose), scaled from head degrees onto the mark.
    static func working(at t: Double) -> BotFacePose {
        let turn = -11 + sin(t * 0.48) * 8
        let tilt = sin(t * 0.42) * 8 + sin(t * 1.1) * 1.6
        let roll = sin(t * 0.75) * 4.2
        let blink = t.truncatingRemainder(dividingBy: 1.45) > 1.26
        return BotFacePose(gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: roll, lid: blink ? 0.06 : 1)
    }
}

/// A `TimelineView` schedule that fires only at blink edges: shut, then open 180 ms
/// later, every 3 to 5 seconds. The period and phase are seeded by the bot's name so
/// a list of faces never blinks in unison. Nothing repaints between entries.
struct BotBlinkSchedule: TimelineSchedule, Equatable {
    static let shutDuration = 0.18
    let period: Double
    let phase: Double

    init(seed: String) {
        let hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        period = 3 + Double(hash % 2001) / 1000
        phase = Double((hash >> 20) % 5000) / 1000
    }

    /// Whether the eyes are shut at `date`; the same rule the entries are cut from.
    func isShut(at date: Date) -> Bool {
        let offset = (date.timeIntervalSinceReferenceDate - phase).truncatingRemainder(dividingBy: period)
        let position = offset < 0 ? offset + period : offset
        // The open entry lands exactly at shutDuration; keep float error from reading it as shut.
        return position + 0.0001 < Self.shutDuration
    }

    func entries(from start: Date, mode: Mode) -> AnySequence<Date> {
        let period = period, shut = Self.shutDuration
        let base = start.timeIntervalSinceReferenceDate
        let firstShut = phase + (floor((base - phase) / period) + 1) * period
        // Starting inside a blink still needs that blink's open edge, or the eyes
        // would stay shut until the next cycle.
        let pendingOpen: Date? = isShut(at: start) ? Date(timeIntervalSinceReferenceDate: firstShut - period + shut) : nil
        return AnySequence { () -> AnyIterator<Date> in
            var index = -1
            let edges = [start] + (pendingOpen.map { [$0] } ?? [])
            return AnyIterator {
                index += 1
                if index < edges.count { return edges[index] }
                let step = index - edges.count
                let blink = firstShut + Double(step / 2) * period
                return Date(timeIntervalSinceReferenceDate: step.isMultiple(of: 2) ? blink : blink + shut)
            }
        }
    }
}

/// One short, self-ending piece of business for the hero face, after Bloub's state
/// catalogue: it starts and ends at rest so it can cut straight in and out of the
/// blink schedule. `pose(at:)` takes progress 0…1 and uses ease-outs, never springs.
enum BotFaceBit: CaseIterable, Equatable, Sendable {
    case glanceLeft, glanceRight, glanceDown, doubleBlink, wobble, hop, spin

    var duration: Double {
        switch self {
        case .glanceLeft, .glanceRight: return 0.9
        // Long enough to cover a burst of typing; repeated cues never restart it.
        case .glanceDown: return 1.6
        case .doubleBlink: return 0.5
        case .wobble: return 0.7
        case .hop: return 0.55
        case .spin: return 0.9
        }
    }

    func pose(at progress: Double) -> BotFacePose {
        // The edges are exactly rest, so float noise never leaves a face a hair off.
        guard progress > 0, progress < 1 else { return .rest }
        let p = progress
        // Out for the first third, hold, back over the last third.
        let hold = p < 0.3 ? Self.easeOut(p / 0.3) : p > 0.7 ? 1 - Self.easeOut((p - 0.7) / 0.3) : 1
        switch self {
        case .glanceLeft: return BotFacePose(gazeX: -0.07 * hold)
        case .glanceRight: return BotFacePose(gazeX: 0.07 * hold)
        case .glanceDown: return BotFacePose(gazeY: 0.06 * hold)
        case .doubleBlink:
            let shut = (0.05..<0.3).contains(p) || (0.45..<0.75).contains(p)
            return BotFacePose(lid: shut ? 0.06 : 1)
        case .wobble:
            return BotFacePose(roll: 9 * sin(p * 2 * .pi) * (1 - p))
        case .hop:
            let arc = sin(p * .pi)
            let squash = p < 0.15 ? 1 - 0.12 * sin(p / 0.15 * .pi) : p > 0.85 ? 1 - 0.12 * sin((p - 0.85) / 0.15 * .pi) : 1
            return BotFacePose(lift: 0.16 * arc, scaleX: 2 - squash, scaleY: squash)
        case .spin:
            let t = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            return BotFacePose(roll: 360 * t)
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

/// When the hero face does something on its own: every 4 to 9 seconds, seeded by
/// the bot's name so two faces never move in step, one bit from the repertoire.
/// A spin is rare: it lands at most every tenth slot, so at least 40 seconds apart.
struct BotPlayfulSchedule: Equatable {
    let seed: UInt64

    init(seed: String) {
        self.seed = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    /// The wait before slot `index` and what plays there.
    func entry(_ index: Int) -> (delay: Double, bit: BotFaceBit) {
        var state = seed ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        state ^= state >> 30; state &*= 0xBF58_476D_1CE4_E5B9
        state ^= state >> 27; state &*= 0x94D0_49BB_1331_11EB
        state ^= state >> 31
        let delay = 4 + Double(state % 5001) / 1000
        let common = BotFaceBit.allCases.filter { $0 != .spin && $0 != .glanceDown }
        let bit: BotFaceBit = index > 0 && index % 10 == 0 ? .spin : common[Int((state >> 16) % UInt64(common.count))]
        return (delay, bit)
    }
}

/// A screen's request for one bit, such as a hop when a shape is picked. A new
/// identity replays the same bit once the previous run has finished.
struct BotFaceCue: Equatable {
    let id = UUID()
    let bit: BotFaceBit
    init(_ bit: BotFaceBit) { self.bit = bit }
}

/// A drawn face that moves per `motion`. The still and Reduce Motion paths render a
/// plain `BotAvatarMarkView` with no timeline at all.
struct BotAnimatedFaceView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var motion: BotFaceMotion = .idle
    /// Extra gaze, as a fraction of the mark size, layered onto the motion's pose.
    var gaze = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch motion.honoring(reduceMotion: reduceMotion) {
        case .still:
            BotAvatarMarkView(name: name, appearance: appearance, size: size, pose: looking(.rest))
        case .idle:
            let schedule = BotBlinkSchedule(seed: name)
            TimelineView(schedule) { context in
                BotAvatarMarkView(name: name, appearance: appearance, size: size,
                                  pose: looking(schedule.isShut(at: context.date) ? .blink : .rest))
            }
        case .working:
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                BotAvatarMarkView(name: name, appearance: appearance, size: size,
                                  pose: looking(.working(at: context.date.timeIntervalSinceReferenceDate)))
            }
        }
    }

    private func looking(_ pose: BotFacePose) -> BotFacePose {
        var pose = pose
        pose.gazeX += gaze.width; pose.gazeY += gaze.height
        return pose
    }
}

/// The hero face on the create and edit screens, after Bloub: it blinks on its own,
/// its eyes follow a finger dragged over it, a tap makes it squish and pull a
/// surprised face for a moment, and every few seconds it plays one short bit
/// (a glance, a double blink, a wobble, a hop, rarely a spin). The screen can cue
/// a bit for what the user just did. A bit runs its own short timeline and then
/// hands back to the blink schedule, so nothing repaints while the face is left
/// alone. Reduce Motion keeps the eyes still, plays no bits and drops the squish,
/// but still answers a tap with the expression.
struct BotInteractiveFaceView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var cue: BotFaceCue?
    @State private var gaze = CGSize.zero
    @State private var reaction = 0
    @State private var playing: (bit: BotFaceBit, start: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the eyes travel, as a fraction of the mark, and the reaction's length.
    private static let reach = 0.07
    private static let reactionDuration: Duration = .milliseconds(650)

    var body: some View {
        var shown = appearance
        if reaction > 0 { shown.expression = BotAvatarExpression.surprised.rawValue }
        return Group {
            if let playing, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    let progress = context.date.timeIntervalSince(playing.start) / playing.bit.duration
                    BotAvatarMarkView(name: name, appearance: shown, size: size, pose: playing.bit.pose(at: progress))
                }
            } else {
                BotAnimatedFaceView(name: name, appearance: shown, size: size, gaze: gaze)
            }
        }
            .scaleEffect(x: reaction > 0 && !reduceMotion ? 1.08 : 1, y: reaction > 0 && !reduceMotion ? 0.92 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !reduceMotion else { return }
                        let dx = (value.location.x - size / 2) / size, dy = (value.location.y - size / 2) / size
                        let length = max(hypot(dx, dy), 0.001), clamp = min(length, 0.5) / length
                        gaze = CGSize(width: dx * clamp * Self.reach * 2, height: dy * clamp * Self.reach * 2)
                    }
                    .onEnded { value in
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { gaze = .zero }
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved < 10 { react() }
                    }
            )
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: reaction > 0)
            .accessibilityHidden(true)
            .onChange(of: cue?.id) { if let cue { play(cue.bit) } }
            .task(id: name) { await playIdleBits() }
    }

    /// Runs the seeded idle repertoire while the face is on screen. A slot whose
    /// moment finds the face busy (a cue, a tap) is simply skipped.
    private func playIdleBits() async {
        guard !reduceMotion else { return }
        let schedule = BotPlayfulSchedule(seed: name)
        var index = 0
        while !Task.isCancelled {
            let entry = schedule.entry(index)
            guard (try? await Task.sleep(for: .seconds(entry.delay))) != nil else { return }
            if playing == nil, reaction == 0 { play(entry.bit) }
            index += 1
        }
    }

    /// A cue for the bit already on screen is ignored, so fast typing looks down
    /// once for the whole burst instead of jittering with every letter.
    private func play(_ bit: BotFaceBit) {
        guard !reduceMotion, playing?.bit != bit else { return }
        let start = Date()
        playing = (bit, start)
        Task {
            try? await Task.sleep(for: .seconds(bit.duration))
            if playing?.start == start { playing = nil }
        }
    }

    private func react() {
        reaction += 1
        let token = reaction
        Task {
            try? await Task.sleep(for: Self.reactionDuration)
            if reaction == token { reaction = 0 }
        }
    }
}
