import Foundation

#if DEBUG || INTERNAL_PERFORMANCE_LAB
import os
#endif

enum ChatPerformancePhase: String, CaseIterable, Codable {
    case eventHandling
    case drainTicks
    case drainedUnits
    case finalFlushes
    case transcriptMappingRows
    case messagePageLoads
    case messagePageRows
    case reasoningGroups
    case progressRecoveryWrites
    case toolStarts
    case toolCompletions
    case metering
    case completions
    case cancellations
    case errors
    case done
    case streamConnections
    case streamIntervals
    case messageLoadIntervals
    case transcriptContentEvaluations
    case transcriptLayoutPasses
    case scrollMetricCallbacks
    case followScrollSchedules
    case followScrollFires
    case markdownBlocks
    case uncachedMathLayouts
    case streamingMarkdownSplits
    case fadeDraws
    case fadeTimelineFrames
}

struct ChatPerformanceSummary: Codable, Equatable {
    let counters: [String: Int]
    let closedIntervals: [String: Int]
    let intervalDurationsNanoseconds: [String: UInt64]
}

#if DEBUG || INTERNAL_PERFORMANCE_LAB
@MainActor
final class ChatPerformanceInstrumentation {
    static let shared = ChatPerformanceInstrumentation()

    private(set) var counters: [ChatPerformancePhase: Int] = [:]
    private(set) var closedIntervals: [ChatPerformancePhase: Int] = [:]
    private(set) var intervalDurationsNanoseconds: [ChatPerformancePhase: UInt64] = [:]
    private var intervalStarts: [ChatPerformancePhase: UInt64] = [:]
    private let signpostLog = OSLog(subsystem: "com.uzairansar.hermesmobile", category: "ChatPerformance")

    private init() {}

    func reset() {
        counters.removeAll(keepingCapacity: true)
        closedIntervals.removeAll(keepingCapacity: true)
        intervalDurationsNanoseconds.removeAll(keepingCapacity: true)
        intervalStarts.removeAll(keepingCapacity: true)
    }

    func record(_ phase: ChatPerformancePhase, units: Int = 1) {
        guard units > 0 else { return }
        counters[phase, default: 0] += units
    }

    func begin(_ phase: ChatPerformancePhase) {
#if DEBUG || INTERNAL_PERFORMANCE_LAB
        if intervalStarts[phase] != nil {
            end(phase)
        }
        intervalStarts[phase] = DispatchTime.now().uptimeNanoseconds
        os_signpost(.begin, log: signpostLog, name: "Chat phase", "%{public}s", phase.rawValue)
#endif
    }

    func end(_ phase: ChatPerformancePhase) {
#if DEBUG || INTERNAL_PERFORMANCE_LAB
        guard let startedAt = intervalStarts.removeValue(forKey: phase) else { return }
        closedIntervals[phase, default: 0] += 1
        let duration = DispatchTime.now().uptimeNanoseconds &- startedAt
        intervalDurationsNanoseconds[phase, default: 0] += duration
        os_signpost(.end, log: signpostLog, name: "Chat phase", "%{public}s", phase.rawValue)
#endif
    }

    var summary: ChatPerformanceSummary {
        ChatPerformanceSummary(
            counters: Dictionary(uniqueKeysWithValues: counters
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { ($0.key.rawValue, $0.value) }),
            closedIntervals: Dictionary(uniqueKeysWithValues: closedIntervals
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { ($0.key.rawValue, $0.value) }),
            intervalDurationsNanoseconds: Dictionary(uniqueKeysWithValues: intervalDurationsNanoseconds
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { ($0.key.rawValue, $0.value) })
        )
    }
}
#else
@MainActor
final class ChatPerformanceInstrumentation {
    static let shared = ChatPerformanceInstrumentation()

    private init() {}

    func reset() {}
    func record(_ phase: ChatPerformancePhase, units: Int = 1) {}
    func begin(_ phase: ChatPerformancePhase) {}
    func end(_ phase: ChatPerformancePhase) {}

    var summary: ChatPerformanceSummary {
        ChatPerformanceSummary(counters: [:], closedIntervals: [:], intervalDurationsNanoseconds: [:])
    }
}
#endif
