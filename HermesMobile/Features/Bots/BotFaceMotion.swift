import SwiftUI

enum BotFaceMotion: Equatable, Sendable {
    case still, idle
    case working(since: Date)

    func honoring(reduceMotion: Bool) -> BotFaceMotion { reduceMotion ? .still : self }
}

struct BotFacePose: Equatable, Sendable {
    var gazeX = 0.0
    var gazeY = 0.0
    var roll = 0.0
    var lid = 1.0
    var lift = 0.0
    var scaleX = 1.0
    var scaleY = 1.0

    static let rest = BotFacePose()
    static let blink = BotFacePose(lid: 0.06)

    static func working(at t: Double) -> BotFacePose {
        let turn = -11 + sin(t * 0.48) * 8
        let tilt = sin(t * 0.42) * 8 + sin(t * 1.1) * 1.6
        let roll = sin(t * 0.75) * 4.2
        let blink = t.truncatingRemainder(dividingBy: 1.45) > 1.26
        return BotFacePose(gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: roll, lid: blink ? 0.06 : 1)
    }

    static let settledWorking = BotFacePose(gazeX: -11 * 0.0025)
}

struct BotBlinkSchedule: TimelineSchedule, Equatable {
    static let shutDuration = 0.18
    let period: Double
    let phase: Double

    init(seed: String) {
        let hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        period = 3 + Double(hash % 2001) / 1000
        phase = Double((hash >> 20) % 5000) / 1000
    }

    func isShut(at date: Date) -> Bool {
        let offset = (date.timeIntervalSinceReferenceDate - phase).truncatingRemainder(dividingBy: period)
        let position = offset < 0 ? offset + period : offset
        return position + 0.0001 < Self.shutDuration
    }

    func entries(from start: Date, mode: Mode) -> AnySequence<Date> {
        let period = period, shut = Self.shutDuration
        let base = start.timeIntervalSinceReferenceDate
        let firstShut = phase + (floor((base - phase) / period) + 1) * period
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

struct BotWorkingSchedule: TimelineSchedule, Equatable {
    static let beat = 30.0
    static let frameInterval = 1.0 / 15
    let start: Date
    let blink: BotBlinkSchedule

    private var end: Date { start.addingTimeInterval(Self.beat) }

    func pose(at date: Date) -> BotFacePose {
        if date < end { return .working(at: date.timeIntervalSinceReferenceDate) }
        var pose = BotFacePose.settledWorking
        if blink.isShut(at: date) { pose.lid = BotFacePose.blink.lid }
        return pose
    }

    func entries(from date: Date, mode: Mode) -> AnySequence<Date> {
        let end = end
        guard date < end else { return blink.entries(from: date, mode: mode) }
        let first = max(date, start), blink = blink
        return AnySequence { () -> AnyIterator<Date> in
            var frame = 0
            let settled = blink.entries(from: end, mode: mode).makeIterator()
            return AnyIterator {
                let next = first.addingTimeInterval(Double(frame) * Self.frameInterval)
                guard next < end else { return settled.next() }
                frame += 1
                return next
            }
        }
    }
}

enum BotTurnState { case unknown, idle, running, needsAttention, interrupted }

struct BotWorkingBeat: Equatable {
    private(set) var start = Date.distantPast
    private var armed = true

    mutating func rearm() { armed = true }

    mutating func observe(_ turn: BotTurnState, at date: Date) {
        switch turn {
        case .running: if armed { start = date; armed = false }
        case .unknown: break
        case .idle, .needsAttention, .interrupted: armed = true
        }
    }
}

enum BotFaceBit: CaseIterable, Equatable, Sendable {
    case glanceLeft, glanceRight, glanceDown, doubleBlink, wobble, hop, spin

    var duration: Double {
        switch self {
        case .glanceLeft, .glanceRight: return 0.9
        case .glanceDown: return 1.6
        case .doubleBlink: return 0.5
        case .wobble: return 0.7
        case .hop: return 0.55
        case .spin: return 0.9
        }
    }

    func pose(at progress: Double) -> BotFacePose {
        guard progress > 0, progress < 1 else { return .rest }
        let p = progress
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

struct BotPlayfulSchedule: Equatable {
    let seed: UInt64

    init(seed: String) {
        self.seed = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

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

struct BotFaceCue: Equatable {
    let id = UUID()
    let bit: BotFaceBit
    init(_ bit: BotFaceBit) { self.bit = bit }
}

struct BotAnimatedFaceView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var motion: BotFaceMotion = .idle
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
        case .working(let since):
            let schedule = BotWorkingSchedule(start: since, blink: BotBlinkSchedule(seed: name))
            TimelineView(schedule) { context in
                BotAvatarMarkView(name: name, appearance: appearance, size: size,
                                  pose: looking(schedule.pose(at: context.date)))
            }
        }
    }

    private func looking(_ pose: BotFacePose) -> BotFacePose {
        var pose = pose
        pose.gazeX += gaze.width; pose.gazeY += gaze.height
        return pose
    }
}

struct BotInteractiveFaceView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var cue: BotFaceCue?
    @State private var gaze = CGSize.zero
    @State private var reaction = 0
    @State private var playing: (bit: BotFaceBit, start: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let reach = 0.07
    private static let reactionDuration: Duration = .milliseconds(650)

    var body: some View {
        var shown = appearance
        if reaction > 0 { shown.expression = BotAvatarExpression.surprised.rawValue }
        return Group {
            if let playing, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    BotAvatarMarkView(name: name, appearance: shown, size: size, pose: bitPose(playing, at: context.date))
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
            .task(id: "\(name)|\(reduceMotion)") { await playIdleBits() }
    }

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

    private func bitPose(_ playing: (bit: BotFaceBit, start: Date), at date: Date) -> BotFacePose {
        var pose = playing.bit.pose(at: date.timeIntervalSince(playing.start) / playing.bit.duration)
        pose.gazeX = max(-Self.reach, min(Self.reach, pose.gazeX + gaze.width))
        pose.gazeY = max(-Self.reach, min(Self.reach, pose.gazeY + gaze.height))
        return pose
    }

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
