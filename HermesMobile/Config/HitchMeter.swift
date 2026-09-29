#if DEBUG
import QuartzCore
import SwiftUI

/// Rolling one-second hitch statistics from display-link frames. A frame is a
/// hitch when it arrives more than half a frame late: the gap since the previous
/// frame exceeds 1.5 × the duration that frame promised
/// (`targetTimestamp − timestamp`). The late time is how far past that promise
/// it landed.
struct HitchAccumulator {
    struct Reading: Equatable {
        let hitchMillisecondsPerSecond: Double
        let hitchCount: Int
        /// The refresh rate the display link reports, not the delivered frame rate.
        let hertz: Double

        /// `33.3 ms/s · 1 hitch · 60 Hz`
        var summary: String {
            let hitches = hitchCount == 1 ? "hitch" : "hitches"
            let milliseconds = String(format: "%.1f", hitchMillisecondsPerSecond)
            return "\(milliseconds) ms/s · \(hitchCount) \(hitches) · \(Int(hertz.rounded())) Hz"
        }
    }

    static let window: CFTimeInterval = 1

    private struct Frame {
        let timestamp: CFTimeInterval
        let duration: CFTimeInterval
        let lateness: CFTimeInterval?
    }

    private var frames: [Frame] = []
    private var previous: (timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval)?

    /// Adds one display-link callback: `timestamp` is when the last frame was
    /// shown, `targetTimestamp` when the next one should be.
    mutating func record(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        var lateness: CFTimeInterval?
        if let previous {
            let expected = previous.targetTimestamp - previous.timestamp
            if timestamp - previous.timestamp > expected * 1.5 {
                lateness = timestamp - previous.targetTimestamp
            }
        }
        previous = (timestamp, targetTimestamp)
        frames.append(Frame(timestamp: timestamp, duration: targetTimestamp - timestamp, lateness: lateness))

        let cutoff = timestamp - Self.window
        if let firstInWindow = frames.firstIndex(where: { $0.timestamp > cutoff }), firstInWindow > 0 {
            frames.removeFirst(firstInWindow)
        }
    }

    var reading: Reading {
        let lateness = frames.compactMap(\.lateness)
        let meanDuration = frames.isEmpty ? 0 : frames.reduce(0) { $0 + $1.duration } / Double(frames.count)
        return Reading(
            hitchMillisecondsPerSecond: lateness.reduce(0, +) * 1000 / Self.window,
            hitchCount: lateness.count,
            hertz: meanDuration > 0 ? 1 / meanDuration : 0
        )
    }
}

/// Feeds `HitchAccumulator` from a `CADisplayLink` in `.common` mode, so it keeps
/// measuring while a scroll view is tracking, and publishes a readout at most
/// twice a second so the meter never repaints every frame.
@MainActor
@Observable
final class HitchMeter: NSObject {
    /// Launch with `--hitch-meter` to show the overlay (`DEVELOPMENT.md`).
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--hitch-meter")

    private(set) var readout = HitchAccumulator().reading.summary

    @ObservationIgnored private var accumulator = HitchAccumulator()
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastPublishedAt: CFTimeInterval = 0

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameDidArrive(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Invalidates the display link, which also releases its hold on `self`.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        accumulator = HitchAccumulator()
    }

    @objc private func frameDidArrive(_ link: CADisplayLink) {
        accumulator.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        guard link.timestamp - lastPublishedAt >= 0.5 else { return }
        lastPublishedAt = link.timestamp
        let summary = accumulator.reading.summary
        if summary != readout {
            readout = summary
        }
    }
}

/// The debug readout pinned to the top-leading safe area. It never takes a
/// touch and VoiceOver skips it. It stops while the scene is not active, so time
/// in the background never counts as a hitch.
struct HitchMeterOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var meter = HitchMeter()

    var body: some View {
        Text(verbatim: meter.readout)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { meter.start() } else { meter.stop() }
            }
    }
}
#endif
