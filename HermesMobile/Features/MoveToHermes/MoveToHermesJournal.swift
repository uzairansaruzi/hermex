import CryptoKit
import Foundation

/// What a Move to Hermes froze at Review (#1216), saved once as `plan.json` before the commit.
/// Resuming works only from this, never from what Review shows later.
struct MoveToHermesReview: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    /// True for the first move of this webui server; false for Copy Missing Chats Again, which
    /// reconciles only chats it confirms copying.
    let firstMove: Bool
    /// The run started over a journal that was lost or damaged, so earlier results are unknown.
    var recovering = false
    /// The Profile mapping the move record holds.
    let profiles: [MovedWebuiProfile]
    /// Every Hermes Profile, for the rechecks before each import.
    let hermesProfiles: [String]
    let entries: [MoveToHermesScan.Entry]
    /// Set when the webui listed only this Profile, so the others went unscanned.
    let onlyProfile: String?

    /// The Hermes Profile `chat`'s Profile maps to, or nil when it stays on the webui or is unmapped.
    func destination(of chat: MoveToHermesSourceChat) -> String? {
        guard case .hermes(let profile)? = profiles.first(where: { $0.source == chat.profile })?.destination else { return nil }
        return profile
    }
}

/// What carrying the webui server's push pairing gave (`MovePushPairingOutcome`), as the log saves it.
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

/// What became of one chat's draft (`MoveToHermesReconcile.DraftOutcome`), as the log saves it.
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

/// One line of a Move's log. An intent (`importing`, `planned`, `changing`, `finished`) is on
/// disk before what it names is sent or saved anywhere else; the rest record what happened.
enum MoveToHermesEvent: Codable, Equatable, Sendable {
    case pairing(MoveToHermesPairing)
    /// One import about to go to `profile` with every chat id in it, within copy `attempt`.
    case importing(profile: String, ids: [String], attempt: UUID)
    /// One copy attempt's outcome for each chat it was given.
    case copied([String: WebuiSessionTransfer.Outcome], attempt: UUID)
    /// Reconcile plans read from Hermes; nothing in them is sent before this line is on disk.
    case planned([String: MoveToHermesReconcile.Planned])
    /// One metadata write about to go out. Its result is the next `changed` for the same field.
    case changing(MoveToHermesReconcile.Operation)
    case changed(MoveToHermesReconcile.Operation, MoveToHermesReconcile.Outcome)
    case drafts([String: MoveToHermesDraftResult])
    /// The move's final report, on disk before the move record is marked complete.
    case finished(MoveToHermesReport)
}

/// One Move to Hermes's work state on disk (#1216): a folder under Application Support named by
/// a hash of both server ids, so it holds no address, with the drafts' file protection.
///
/// - `plan.json` is the frozen Review, written once, before the commit.
/// - `log.jsonl` gets one JSON line per event, numbered from 1. Intents are flushed to disk
///   before `append` returns, and nothing they name is sent until then. Outcome lines are
///   written without their own flush; the next intent's flush covers them.
///
/// Reading it back:
/// - A last line with no newline was cut short by a quit or a crash, and is cut off. Its own
///   write never finished, so if it was an intent, nothing it names was sent. If it was an
///   outcome, the intent before it is complete and its work counts as in flight: an import is
///   sent again (the host skips ids it has), a metadata write is only checked, never resent.
/// - A missing log, or a complete line that doesn't decode, breaks the numbering, or names a chat
///   or Profile the plan doesn't hold, makes the journal `.damaged`. Nothing is done from a damaged journal;
///   the user starts over from a fresh scan, as when the journal is lost.
/// - A file that can't be read now (locked before first unlock, an I/O error, a newer format)
///   is `.unreadable`: it is kept and read again later, never treated as damaged or deleted.
@MainActor final class MoveToHermesJournal {
    /// A write the journal is about to make, for tests that fail or interrupt one.
    enum Write: Equatable {
        case plan
        case event(MoveToHermesEvent)
    }

    enum Opened {
        case ready(MoveToHermesJournal)
        /// No folder, or no `plan.json` in it.
        case missing
        case damaged
        case unreadable
    }

    struct Damaged: Error {}

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoveToHermes", isDirectory: true)
    }

    /// Folders a runner in this process holds; orphan cleanup leaves them alone.
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

    /// The folder for moving `source` to `destination`: a hash of both ids, never the ids.
    static func folder(source: String, destination: String, in root: URL) -> URL {
        let digest = SHA256.hash(data: Data("\(source)\u{0}\(destination)".utf8))
        return root.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    /// Writes `review` as a new journal's `plan.json`, flushed, with an empty log. Throws, leaving
    /// no folder, when it can't.
    static func create(_ review: MoveToHermesReview, at folder: URL,
                       willWrite: @escaping @MainActor (Write) throws -> Void = { _ in }) throws -> MoveToHermesJournal {
        let files = FileManager.default
        do {
            try willWrite(.plan)
            try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            // The log first: a `plan.json` without its log is a journal that lost its history.
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

    /// Reads the journal at `folder`, cutting off a torn last line first.
    static func open(_ folder: URL, willWrite: @escaping @MainActor (Write) throws -> Void = { _ in }) -> Opened {
        let files = FileManager.default
        let plan = folder.appendingPathComponent("plan.json")
        guard files.fileExists(atPath: plan.path) else { return .missing }
        guard let planData = try? Data(contentsOf: plan) else { return .unreadable }
        guard let version = try? JSONDecoder().decode(Version.self, from: planData) else { return .damaged }
        guard version.version <= MoveToHermesReview.currentVersion else { return .unreadable }
        guard let review = try? JSONDecoder().decode(MoveToHermesReview.self, from: planData) else { return .damaged }
        let log = logURL(in: folder)
        // Without its log, nothing says what was sent; replaying from an empty one could resend.
        guard files.fileExists(atPath: log.path) else { return .damaged }
        guard let data = try? Data(contentsOf: log) else { return .unreadable }
        // Everything after the last newline is a line whose write never finished.
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

    /// Appends `event`. With `durable`, it is flushed to disk before this returns, so an intent
    /// is never acted on before it can survive a crash. On failure the line is cut off again and
    /// this throws; the caller must not act on it.
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

    /// Deletes the whole journal: on Done, or when the move never committed.
    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// Holds `folder` for a runner in this process; false when another already does.
    static func claim(_ folder: URL) -> Bool { claimed.insert(folder.standardizedFileURL).inserted }

    static func release(_ folder: URL) { claimed.remove(folder.standardizedFileURL) }

    static func isClaimed(_ folder: URL) -> Bool { claimed.contains(folder.standardizedFileURL) }

    /// The report a `finished` line saved, once the move has one.
    var finishedReport: MoveToHermesReport? {
        for event in events.reversed() {
            if case .finished(let report) = event { return report }
        }
        return nil
    }

    /// Deletes the journals of the moves `destinationID` held. `AuthManager.removeServer` calls
    /// it after the destination's entry is gone, so a runner's next write finds no record and
    /// stops rather than writing to a journal again.
    static func discard(sources: [String], destinationID: String, in root: URL = defaultRoot) {
        for source in sources {
            try? FileManager.default.removeItem(at: folder(source: source, destination: destinationID, in: root))
        }
    }

    // MARK: Reading

    private struct Line: Codable {
        let seq: Int
        let event: MoveToHermesEvent
    }

    private struct Version: Decodable {
        let version: Int
    }

    private static func logURL(in folder: URL) -> URL { folder.appendingPathComponent("log.jsonl") }

    /// The complete lines of a log, checked against the plan they belong to: every chat, Profile
    /// and planned write a line names must be one the frozen Review allows, so a damaged line can
    /// never point a write at another chat.
    private static func decode(_ data: Data, against review: MoveToHermesReview) throws -> [MoveToHermesEvent] {
        let ids = Set(review.entries.map(\.chat.id))
        let destinations = Set(review.entries.compactMap { review.destination(of: $0.chat) })
        // An import goes to a mapped destination, which a repeat move takes from the record and
        // may be missing from the Hermes Profiles listed at its Review.
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

/// A move the app hasn't closed: unfinished, finished with its report not yet seen, or one whose
/// journal can't be used (#1216).
struct MoveToHermesPending: Equatable {
    enum Status: Equatable {
        case unfinished
        /// Its final report is saved and waits for Done.
        case finished(MoveToHermesReport)
        /// The journal can't be trusted; Copy Missing Chats Again from a fresh scan starts over.
        case damaged
        /// The journal can't be read right now; try again later.
        case unreadable
        /// The move isn't complete and its journal is gone; start over from a fresh scan.
        case needsRescan
    }

    let sourceServerID: String
    let destinationID: String
    let status: Status

    /// Every move in `servers` that isn't closed. Deletes journal folders no record owns, such
    /// as one whose commit never happened, unless a runner in this process holds it.
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
