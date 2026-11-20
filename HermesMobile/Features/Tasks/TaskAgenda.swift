import Foundation

enum TaskFilter: Int, CaseIterable, Identifiable {
    case all
    case live
    case paused
    case errors

    var id: Int { rawValue }

    func title(count: Int) -> String {
        switch self {
        case .all:
            return String(localized: "All \(count)")
        case .live:
            return String(localized: "Live \(count)")
        case .paused:
            return String(localized: "Paused \(count)")
        case .errors:
            return String(localized: "Errors \(count)")
        }
    }
}

enum TaskAgendaGroup: Int, CaseIterable, Identifiable {
    case now
    case laterToday
    case tomorrow
    case thisWeek
    case later
    case needsAttention
    case paused

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .now:
            return String(localized: "Now")
        case .laterToday:
            return String(localized: "Later Today")
        case .tomorrow:
            return String(localized: "Tomorrow")
        case .thisWeek:
            return String(localized: "This Week")
        case .later:
            return String(localized: "Later")
        case .needsAttention:
            return String(localized: "Needs Attention")
        case .paused:
            return String(localized: "Paused")
        }
    }
}

struct TaskAgendaSection: Identifiable {
    let group: TaskAgendaGroup
    let jobs: [CronJob]

    var id: Int { group.id }
}

enum TaskAgenda {
    static func group(
        for job: CronJob,
        isRunning: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> TaskAgendaGroup {
        if isRunning { return .now }
        if job.hasFailedRun { return .needsAttention }
        guard job.isLive else { return .paused }
        guard let next = job.nextRunAt?.date else { return .later }

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday),
              let weekHorizon = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        else { return .later }

        if next < startOfTomorrow { return .laterToday }
        if next < startOfDayAfterTomorrow { return .tomorrow }
        if next < weekHorizon { return .thisWeek }
        return .later
    }

    static func matches(_ job: CronJob, filter: TaskFilter, isRunning: Bool) -> Bool {
        switch filter {
        case .all:
            return true
        case .live:
            return isRunning || job.isLive
        case .paused:
            return !isRunning && !job.isLive
        case .errors:
            return job.hasFailedRun
        }
    }

    static func count(
        of filter: TaskFilter,
        in jobs: [CronJob],
        runningJobIDs: Set<String>
    ) -> Int {
        jobs.reduce(into: 0) { total, job in
            if matches(job, filter: filter, isRunning: isRunning(job, in: runningJobIDs)) {
                total += 1
            }
        }
    }

    static func sections(
        jobs: [CronJob],
        runningJobIDs: Set<String>,
        filter: TaskFilter,
        now: Date,
        calendar: Calendar = .current
    ) -> [TaskAgendaSection] {
        var grouped: [TaskAgendaGroup: [CronJob]] = [:]

        for job in jobs {
            let running = isRunning(job, in: runningJobIDs)
            guard matches(job, filter: filter, isRunning: running) else { continue }
            let group = group(for: job, isRunning: running, now: now, calendar: calendar)
            grouped[group, default: []].append(job)
        }

        return TaskAgendaGroup.allCases.compactMap { group in
            guard let jobs = grouped[group], !jobs.isEmpty else { return nil }
            return TaskAgendaSection(group: group, jobs: jobs.sorted(by: precedes))
        }
    }

    static func isRunning(_ job: CronJob, in runningJobIDs: Set<String>) -> Bool {
        guard let jobID = job.jobId else { return false }
        return runningJobIDs.contains(jobID)
    }

    private static func precedes(_ left: CronJob, _ right: CronJob) -> Bool {
        switch (left.nextRunAt?.date, right.nextRunAt?.date) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }
}

extension CronJob {
    var isLive: Bool {
        enabled != false && state != "paused"
    }

    var hasFailedRun: Bool {
        if lastStatus == "error" { return true }
        if let lastError, !lastError.isEmpty { return true }
        if let lastDeliveryError, !lastDeliveryError.isEmpty { return true }
        return false
    }

    var failureSummary: String? {
        for candidate in [lastError, lastDeliveryError] {
            guard let candidate, !candidate.isEmpty else { continue }
            if let summary = candidate.firstLineSummary() { return summary }
        }
        return nil
    }

    var scheduleDescription: CronScheduleDescription? {
        CronScheduleHumanizer.describe(editableScheduleText ?? scheduleText)
    }

    var shouldResume: Bool {
        status == .paused || status == .off
    }

    var pauseResumeTitle: String {
        shouldResume ? String(localized: "Resume") : String(localized: "Pause")
    }

    var pauseResumeSystemImage: String {
        shouldResume ? "play.circle" : "pause.fill"
    }
}
