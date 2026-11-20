#if DEBUG
import QuartzCore
import SwiftUI

struct HitchAccumulator {
    struct Reading: Equatable {
        let hitchMillisecondsPerSecond: Double
        let hitchCount: Int
        let hertz: Double

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

@MainActor
@Observable
final class HitchMeter: NSObject {
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

struct HitchMeterOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var meter = HitchMeter()

    var body: some View {
        Text(verbatim: meter.readout)
            .font(AppFont.caption2().monospacedDigit())
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
