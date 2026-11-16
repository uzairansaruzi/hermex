import CryptoKit
import Foundation
import MetricKit

/// Receives MetricKit's crash, hang, CPU and disk-write diagnostics for the app's lifetime and keeps
/// them in `DiagnosticsStore` for About → Diagnostics (#1397). `PushAppDelegate` retains one and
/// registers it at launch. iOS decides when, and whether, to deliver a report, and only for the
/// main app: the extensions are not covered. MetricKit calls in off the main thread, and the
/// payload is projected and stored there; nothing is uploaded.
final class DiagnosticsLog: NSObject, MXMetricManagerSubscriber {
    private let store: DiagnosticsStore

    init(store: DiagnosticsStore = .shared) {
        self.store = store
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let received = Date()
        for payload in payloads {
            let reports = DiagnosticReport.reports(
                fromPayload: payload.jsonRepresentation(),
                begin: payload.timeStampBegin,
                end: payload.timeStampEnd
            )
            store.save(reports, receivedAt: received)
        }
    }
}

/// One MetricKit diagnostic as Hermex keeps and copies it: its kind, the payload's time window
/// (when the diagnostic happened, not an exact moment), the app version, numeric codes, Apple's
/// measurement for the kind, and bounded stack frames that can be symbolicated off the device.
/// Keys follow Apple's payload JSON so the copy reads like MetricKit's own.
struct DiagnosticReport: Codable, Equatable {
    enum Kind: String, Codable {
        case crash, hang, cpu, diskWrites
    }

    /// One thread's frames, or one aggregated tree for hang and CPU reports.
    struct CallStack: Codable, Equatable {
        var threadAttributed: Bool?
        var frames: [Frame]
    }

    struct Frame: Codable, Equatable {
        var binaryUUID: String?
        /// The binary's file name, never its path.
        var binaryName: String?
        var offsetIntoBinaryTextSegment: Int?
        var subFrames: [Frame]?
    }

    var kind: Kind
    var windowStart: Date
    var windowEnd: Date
    var appVersion: String?
    var appBuildVersion: String?
    var signal: Int?
    var exceptionType: Int?
    var exceptionCode: Int?
    var hangDuration: String?
    var totalCPUTime: String?
    var writesCaused: String?
    var callStacks: [CallStack]
}

extension DiagnosticReport {
    /// Most frames one report keeps, across all its stacks, the attributed thread first.
    static let frameBudget = 128

    /// One report per diagnostic in MetricKit's payload JSON (`MXDiagnosticPayload.jsonRepresentation()`),
    /// read tolerantly: a missing or mistyped field leaves that field nil and never drops the
    /// diagnostic. Only the fields above are read. Exception and termination messages, VM region
    /// info, signposts, and device, OS and locale metadata can hold user text, paths or device
    /// details, and never leave this function.
    static func reports(fromPayload json: Data, begin: Date, end: Date) -> [DiagnosticReport] {
        guard let payload = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        let arrays: [(Kind, String)] = [
            (.crash, "crashDiagnostics"),
            (.hang, "hangDiagnostics"),
            (.cpu, "cpuExceptionDiagnostics"),
            (.diskWrites, "diskWriteExceptionDiagnostics"),
        ]
        return arrays.flatMap { kind, key in
            ((payload[key] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { diagnostic in
                let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
                return DiagnosticReport(
                    kind: kind,
                    windowStart: min(begin, end),
                    windowEnd: max(begin, end),
                    appVersion: short(meta["appVersion"]),
                    appBuildVersion: short(meta["appBuildVersion"]),
                    signal: meta["signal"] as? Int,
                    exceptionType: meta["exceptionType"] as? Int,
                    exceptionCode: meta["exceptionCode"] as? Int,
                    hangDuration: short(meta["hangDuration"]),
                    totalCPUTime: short(meta["totalCPUTime"]),
                    writesCaused: short(meta["writesCaused"]),
                    callStacks: callStacks(diagnostic["callStackTree"])
                )
            }
        }
    }

    private static func callStacks(_ tree: Any?) -> [CallStack] {
        let stacks = ((tree as? [String: Any])?["callStacks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        // The thread that crashed or hung comes first, so the budget spends on it.
        let ordered = stacks.filter { $0["threadAttributed"] as? Bool == true }
            + stacks.filter { $0["threadAttributed"] as? Bool != true }
        var budget = frameBudget
        return ordered.compactMap { stack in
            guard let frames = frames(stack["callStackRootFrames"], budget: &budget) else { return nil }
            return CallStack(threadAttributed: stack["threadAttributed"] as? Bool, frames: frames)
        }
    }

    /// The frames in `list`, depth first, until `budget` runs out; nil when none are kept.
    private static func frames(_ list: Any?, budget: inout Int) -> [Frame]? {
        var frames: [Frame] = []
        for case let frame as [String: Any] in list as? [Any] ?? [] {
            guard budget > 0 else { break }
            budget -= 1
            frames.append(Frame(
                binaryUUID: short(frame["binaryUUID"]),
                binaryName: short((frame["binaryName"] as? String).map { ($0 as NSString).lastPathComponent }),
                offsetIntoBinaryTextSegment: frame["offsetIntoBinaryTextSegment"] as? Int,
                subFrames: Self.frames(frame["subFrames"], budget: &budget)
            ))
        }
        return frames.isEmpty ? nil : frames
    }

    /// A string field cut to a length that fits a version, UUID, binary name or measurement.
    private static func short(_ value: Any?) -> String? {
        (value as? String).map { String($0.prefix(64)) }
    }
}

/// The kept reports on disk: one JSON file per report under Application Support/Diagnostics, in the
/// main app's container only and excluded from backup, named by a hash of its content so a
/// repeated delivery is stored once. At most `maxCount` files, `maxAge` old and `maxBytes` in
/// total are kept; the rest are removed on every save and every read, so an idle install never
/// shows an expired report. Every call holds one lock, and a report received before a delete
/// that covers it is dropped, so a delivery still in flight can't bring a deleted report back.
/// A save that keeps a new report posts `didSaveNotification`, from the caller's thread, with the
/// store as its object.
final class DiagnosticsStore: @unchecked Sendable {
    /// A kept file: its report and the exact text About previews and copies, or neither when the
    /// file can't be read.
    struct Entry: Identifiable, Equatable {
        let id: String
        let received: Date
        let report: DiagnosticReport?
        let text: String?
    }

    static let didSaveNotification = Notification.Name("DiagnosticsStore.didSave")

    static let shared = DiagnosticsStore(
        directory: URL.applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    )

    private let directory: URL
    private let maxCount: Int
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var clearedAt = Date.distantPast
    private var deletedAt: [String: Date] = [:]

    init(
        directory: URL,
        maxCount: Int = 10,
        maxAge: TimeInterval = 14 * 24 * 60 * 60,
        maxBytes: Int = 2 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxCount = maxCount
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.now = now
    }

    /// Writes each report not already kept, dated `receivedAt`: when MetricKit handed it over.
    func save(_ reports: [DiagnosticReport], receivedAt: Date) {
        let didKeep = lock.withLock {
            var didKeep = false
            var directory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            for report in reports {
                guard let data = try? Self.encoder.encode(report) else { continue }
                let id = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
                let file = directory.appending(path: "\(id).json")
                guard receivedAt >= max(clearedAt, deletedAt[id] ?? .distantPast),
                      !FileManager.default.fileExists(atPath: file.path) else { continue }
                do {
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try FileManager.default.setAttributes([.modificationDate: receivedAt], ofItemAtPath: file.path)
                    didKeep = true
                } catch {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            _ = prunedEntries()
            return didKeep
        }
        if didKeep {
            NotificationCenter.default.post(name: Self.didSaveNotification, object: self)
        }
    }

    /// The kept reports, newest diagnostic window first, after removing any past the limits.
    func entries() -> [Entry] {
        lock.withLock { prunedEntries() }
    }

    func delete(id: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: directory.appending(path: "\(id).json"))
            deletedAt[id] = now()
        }
    }

    func deleteAll() {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            clearedAt = now()
        }
    }

    private func prunedEntries() -> [Entry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .map { file in
                let values = try? file.resourceValues(forKeys: keys)
                return (file: file, received: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
            .sorted { ($0.received, $0.file.lastPathComponent) > ($1.received, $1.file.lastPathComponent) }
        let oldest = now().addingTimeInterval(-maxAge)
        var kept: [Entry] = []
        var bytes = 0
        for (file, received, size) in files {
            guard kept.count < maxCount, received >= oldest, bytes + size <= maxBytes else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            bytes += size
            let data = try? Data(contentsOf: file)
            let report = data.flatMap { try? Self.decoder.decode(DiagnosticReport.self, from: $0) }
            kept.append(Entry(
                id: file.deletingPathExtension().lastPathComponent,
                received: received,
                report: report,
                text: report == nil ? nil : data.flatMap { String(data: $0, encoding: .utf8) }
            ))
        }
        // Retention goes by receipt, but one delivery can carry several windows, so the list
        // orders by when each diagnostic happened; an unreadable file falls back to its receipt.
        return kept.sorted {
            ($0.report?.windowEnd ?? $0.received, $0.received, $0.id) > ($1.report?.windowEnd ?? $1.received, $1.received, $1.id)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
