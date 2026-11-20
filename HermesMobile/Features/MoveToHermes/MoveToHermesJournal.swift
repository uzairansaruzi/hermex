import CryptoKit
import Foundation

struct MoveToHermesReview: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    let firstMove: Bool
    var recovering = false
    let profiles: [MovedWebuiProfile]
    let hermesProfiles: [String]
    let entries: [MoveToHermesScan.Entry]
    let onlyProfile: String?

    func destination(of chat: MoveToHermesSourceChat) -> String? {
        guard case .hermes(let profile)? = profiles.first(where: { $0.source == chat.profile })?.destination else { return nil }
        return profile
    }
}

enum MoveToHermesPairing: String, Codable, Sendable {
    case sourceUnpaired, destinationAlreadyPaired, copied, differentInstall, unchecked

    init(_ outcome: MovePushPairingOutcome) {
        switch outcome {
        case .sourceUnpaired: self = .sourceUnpaired
        case .destinationAlreadyPaired: self = .destinationAlreadyPaired
        case .copied: self = .copied
        case .differentInstall: self = .differentInstall
        case .unchecked: self = .unchecked
        }
    }
}

enum MoveToHermesDraftResult: String, Codable, Sendable {
    case moved, alreadyMoved, nothingToMove, conflict, unverified, missing, failed

    init(_ outcome: MoveToHermesReconcile.DraftOutcome) {
        switch outcome {
        case .moved(.moved): self = .moved
        case .moved(.alreadyMoved): self = .alreadyMoved
        case .moved(.nothingToMove): self = .nothingToMove
        case .moved(.conflict): self = .conflict
        case .unverified: self = .unverified
        case .missing: self = .missing
        case .failed: self = .failed
        }
    }
}

enum MoveToHermesEvent: Codable, Equatable, Sendable {
    case pairing(MoveToHermesPairing)
    case importing(profile: String, ids: [String], attempt: UUID)
    case copied([String: WebuiSessionTransfer.Outcome], attempt: UUID)
    case planned([String: MoveToHermesReconcile.Planned])
    case changing(MoveToHermesReconcile.Operation)
    case changed(MoveToHermesReconcile.Operation, MoveToHermesReconcile.Outcome)
    case drafts([String: MoveToHermesDraftResult])
    case finished(MoveToHermesReport)
}

@MainActor final class MoveToHermesJournal {
    enum Write: Equatable {
        case plan
        case event(MoveToHermesEvent)
    }

    enum Opened {
        case ready(MoveToHermesJournal)
        case missing
        case damaged
        case unreadable
    }

    struct Damaged: Error {}

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoveToHermes", isDirectory: true)
    }

    private static var claimed: Set<URL> = []

    let folder: URL
    let review: MoveToHermesReview
    private(set) var events: [MoveToHermesEvent]
    private let willWrite: @MainActor (Write) throws -> Void
    private var handle: FileHandle?

    private init(folder: URL, review: MoveToHermesReview, events: [MoveToHermesEvent],
                 willWrite: @escaping @MainActor (Write) throws -> Void) {
        self.folder = folder
        self.review = review
        self.events = events
        self.willWrite = willWrite
    }

    static func folder(source: String, destination: String, in root: URL) -> URL {
        let digest = SHA256.hash(data: Data("\(source)\u{0}\(destination)".utf8))
        return root.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    static func create(_ review: MoveToHermesReview, at folder: URL,
                       willWrite: @escaping @MainActor (Write) throws -> Void = { _ in }) throws -> MoveToHermesJournal {
        let files = FileManager.default
        do {
            try willWrite(.plan)
            try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            guard files.createFile(atPath: logURL(in: folder).path, contents: nil,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            else { throw CocoaError(.fileWriteUnknown) }
            let plan = folder.appendingPathComponent("plan.json")
            try JSONEncoder().encode(review).write(to: plan, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try sync(plan)
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
        return MoveToHermesJournal(folder: folder, review: review, events: [], willWrite: willWrite)
    }

    static func open(_ folder: URL, willWrite: @escaping @MainActor (Write) throws -> Void = { _ in }) -> Opened {
        let files = FileManager.default
        let plan = folder.appendingPathComponent("plan.json")
        guard files.fileExists(atPath: plan.path) else { return .missing }
        guard let planData = try? Data(contentsOf: plan) else { return .unreadable }
        guard let version = try? JSONDecoder().decode(Version.self, from: planData) else { return .damaged }
        guard version.version <= MoveToHermesReview.currentVersion else { return .unreadable }
        guard let review = try? JSONDecoder().decode(MoveToHermesReview.self, from: planData) else { return .damaged }
        let log = logURL(in: folder)
        guard files.fileExists(atPath: log.path) else { return .damaged }
        guard let data = try? Data(contentsOf: log) else { return .unreadable }
        let complete = data.lastIndex(of: 0x0A).map { data.prefix(through: $0) } ?? Data()
        if complete.count < data.count {
            do {
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(complete.count))
                try handle.synchronize()
            } catch {
                return .unreadable
            }
        }
        do {
            let events = try decode(complete, against: review)
            return .ready(MoveToHermesJournal(folder: folder, review: review, events: events, willWrite: willWrite))
        } catch {
            return .damaged
        }
    }

    func append(_ event: MoveToHermesEvent, durable: Bool) throws {
        var data = try JSONEncoder().encode(Line(seq: events.count + 1, event: event))
        data.append(0x0A)
        let handle = try openHandle()
        let offset = try handle.seekToEnd()
        do {
            try willWrite(.event(event))
            try handle.write(contentsOf: data)
            if durable { try handle.synchronize() }
        } catch {
            try? handle.truncate(atOffset: offset)
            try? handle.close()
            self.handle = nil
            throw error
        }
        events.append(event)
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: folder)
    }

    static func claim(_ folder: URL) -> Bool { claimed.insert(folder.standardizedFileURL).inserted }

    static func release(_ folder: URL) { claimed.remove(folder.standardizedFileURL) }

    static func isClaimed(_ folder: URL) -> Bool { claimed.contains(folder.standardizedFileURL) }

    var finishedReport: MoveToHermesReport? {
        for event in events.reversed() {
            if case .finished(let report) = event { return report }
        }
        return nil
    }

    static func discard(sources: [String], destinationID: String, in root: URL = defaultRoot) {
        for source in sources {
            try? FileManager.default.removeItem(at: folder(source: source, destination: destinationID, in: root))
        }
    }

    private struct Line: Codable {
        let seq: Int
        let event: MoveToHermesEvent
    }

    private struct Version: Decodable {
        let version: Int
    }

    private static func logURL(in folder: URL) -> URL { folder.appendingPathComponent("log.jsonl") }

    private static func decode(_ data: Data, against review: MoveToHermesReview) throws -> [MoveToHermesEvent] {
        let ids = Set(review.entries.map(\.chat.id))
        let destinations = Set(review.entries.compactMap { review.destination(of: $0.chat) })
        let profiles = Set(review.hermesProfiles).union(destinations)
        var events: [MoveToHermesEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let decoded = try JSONDecoder().decode(Line.self, from: line)
            guard decoded.seq == events.count + 1 else { throw Damaged() }
            let named: [String]
            switch decoded.event {
            case .importing(let profile, let chats, _):
                guard destinations.contains(profile) else { throw Damaged() }
                named = chats
            case .copied(let outcomes, _):
                for outcome in outcomes.values {
                    switch outcome {
                    case .imported(let profile), .alreadyPresent(let profile), .uncertain(let profile):
                        guard profiles.contains(profile) else { throw Damaged() }
                    case .ambiguous(let found):
                        guard profiles.isSuperset(of: found) else { throw Damaged() }
                    case .oversized, .rejected, .unreadable, .unknown, .notSent: break
                    }
                }
                named = Array(outcomes.keys)
            case .planned(let plans):
                for (id, planned) in plans {
                    guard case .plan(let plan) = planned else { continue }
                    guard plan.target.chat.id == id, profiles.contains(plan.target.profile),
                          plan.draftSession == nil || plan.draftSession == id,
                          plan.operations.allSatisfy({ $0.id == id && $0.profile == plan.target.profile })
                    else { throw Damaged() }
                }
                named = Array(plans.keys)
            case .changing(let operation), .changed(let operation, _):
                guard profiles.contains(operation.profile) else { throw Damaged() }
                named = [operation.id]
            case .drafts(let results): named = Array(results.keys)
            case .pairing, .finished: named = []
            }
            guard ids.isSuperset(of: named) else { throw Damaged() }
            events.append(decoded.event)
        }
        return events
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let opened = try FileHandle(forWritingTo: Self.logURL(in: folder))
        handle = opened
        return opened
    }

    private static func sync(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

struct MoveToHermesPending: Equatable {
    enum Status: Equatable {
        case unfinished
        case finished(MoveToHermesReport)
        case damaged
        case unreadable
        case needsRescan
    }

    let sourceServerID: String
    let destinationID: String
    let status: Status

    @MainActor
    static func all(in servers: [ServerAccount], root: URL = MoveToHermesJournal.defaultRoot) -> [MoveToHermesPending] {
        var owned = Set<URL>()
        var pending: [MoveToHermesPending] = []
        for server in servers {
            for record in server.movedWebuiServers {
                let folder = MoveToHermesJournal.folder(source: record.sourceServerID, destination: server.id, in: root)
                owned.insert(folder.standardizedFileURL)
                let status: Status?
                switch MoveToHermesJournal.open(folder) {
                case .ready(let journal): status = journal.finishedReport.map(Status.finished) ?? .unfinished
                case .missing: status = record.completedAt == nil ? .needsRescan : nil
                case .damaged: status = .damaged
                case .unreadable: status = .unreadable
                }
                if let status {
                    pending.append(MoveToHermesPending(sourceServerID: record.sourceServerID, destinationID: server.id, status: status))
                }
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !owned.contains(folder.standardizedFileURL) && !MoveToHermesJournal.isClaimed(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
        return pending
    }
}
