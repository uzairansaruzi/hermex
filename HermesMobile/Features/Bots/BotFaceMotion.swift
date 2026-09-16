import SwiftUI

/// How a drawn bot face moves. `.still` is one frozen frame, used by tile grids,
/// Reduce Motion and the extensions. `.idle` blinks on a sparse schedule. `.working`
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
        let period = period, phase = phase
        let base = start.timeIntervalSinceReferenceDate
        let firstShut = phase + (floor((base - phase) / period) + 1) * period
        return AnySequence { () -> AnyIterator<Date> in
            var index = -1
            return AnyIterator {
                index += 1
                if index == 0 { return start }
                let blink = firstShut + Double((index - 1) / 2) * period
                return Date(timeIntervalSinceReferenceDate: (index - 1).isMultiple(of: 2) ? blink : blink + Self.shutDuration)
            }
        }
    }
}

/// A drawn face that moves per `motion`. The still and Reduce Motion paths render a
/// plain `BotAvatarMarkView` with no timeline at all.
struct BotAnimatedFaceView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var motion: BotFaceMotion = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch motion.honoring(reduceMotion: reduceMotion) {
        case .still:
            BotAvatarMarkView(name: name, appearance: appearance, size: size)
        case .idle:
            let schedule = BotBlinkSchedule(seed: name)
            TimelineView(schedule) { context in
                BotAvatarMarkView(name: name, appearance: appearance, size: size,
                                  pose: schedule.isShut(at: context.date) ? .blink : .rest)
            }
        case .working:
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                BotAvatarMarkView(name: name, appearance: appearance, size: size,
                                  pose: .working(at: context.date.timeIntervalSinceReferenceDate))
            }
        }
    }
}
