import Foundation
import os

/// Remembers watch-started runs so Stop still works after the iPhone app
/// is relaunched. Stream ids are not credentials; they expire after six hours.
public protocol WatchIssuedRunStoring: Sendable {
    func load() -> [RunKey]
    func save(_ runs: [RunKey])
}

public struct WatchIssuedRunFileStore: WatchIssuedRunStoring, Sendable {
    private let fileURL: URL
    private let lock = OSAllocatedUnfairLock()
    private static let lifetime: TimeInterval = 6 * 60 * 60

    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("hermex-watch-issued-runs.json")
    }

    public func load() -> [RunKey] {
        lock.withLock { loadLocked().map(\.run) }
    }

    public func save(_ runs: [RunKey]) {
        lock.withLock {
            var previous: [String: Date] = [:]
            for stamp in loadLocked() {
                previous[stamp.run.streamID] = stamp.savedAt
            }
            let now = Date()
            let stamped = runs.map { run in
                StampedRun(run: run, savedAt: previous[run.streamID] ?? now)
            }
            let folder = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(stamped) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadLocked() -> [StampedRun] {
        guard let data = try? Data(contentsOf: fileURL),
              let stamped = try? JSONDecoder().decode([StampedRun].self, from: data)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        return stamped.filter { $0.savedAt > cutoff }
    }

    private struct StampedRun: Codable {
        var run: RunKey
        var savedAt: Date
    }
}
