import CryptoKit
import Foundation
import MetricKit

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

struct DiagnosticReport: Codable, Equatable {
    enum Kind: String, Codable {
        case crash, hang, cpu, diskWrites
    }

    struct CallStack: Codable, Equatable {
        var threadAttributed: Bool?
        var frames: [Frame]
    }

    struct Frame: Codable, Equatable {
        var binaryUUID: String?
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
    static let frameBudget = 128

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
        let ordered = stacks.filter { $0["threadAttributed"] as? Bool == true }
            + stacks.filter { $0["threadAttributed"] as? Bool != true }
        var budget = frameBudget
        return ordered.compactMap { stack in
            guard let frames = frames(stack["callStackRootFrames"], budget: &budget) else { return nil }
            return CallStack(threadAttributed: stack["threadAttributed"] as? Bool, frames: frames)
        }
    }

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

    private static func short(_ value: Any?) -> String? {
        (value as? String).map { String($0.prefix(64)) }
    }
}

final class DiagnosticsStore: @unchecked Sendable {
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
