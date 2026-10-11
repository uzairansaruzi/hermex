import Foundation

/// A session change a Hermes host refused with its reason (#1048): a PATCH's 400 `{detail}`,
/// such as a title already in use, over 100 characters, or the canonical Bot Chat's. The
/// message is the host's own words, shown as they are.
struct HermesSessionRefusal: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Duplicate on a Hermes row (#1051): an independent copy with every row the session's export
/// holds, tool output, reasoning and timestamps included, which `session.branch_stored` would
/// drop. The export (#1048) is imported under a new id with no parent, then titled.
///
/// The import is all-or-nothing: a refused one leaves nothing behind. It skips an id the Profile
/// already has rather than writing over it, and fails the whole import on a title in use, so
/// the copy goes in untitled and is titled after, "<title> (copy)", then "(copy 2)" and on while
/// the host has the title. A copy the host won't title stays untitled.
enum HermesSessionDuplication {
    /// The host's import limits per session: 10,000 messages, and 5 MB of JSON. A whole request
    /// past 25 MB is 413.
    static let messageLimit = 10_000
    static let byteLimit = 5 * 1024 * 1024
    /// How many titles a copy tries before it stays untitled.
    static let titleAttempts = 10

    struct TooLarge: LocalizedError, Equatable {
        var errorDescription: String? { String(localized: "This session is too large to duplicate.") }
    }

    /// Copies the session `key` of `profile`, titled after `title`, and returns the copy's key
    /// and the title the host kept, nil when it stayed untitled. Throws `TooLarge` past the host's
    /// limits, the host's refusal as `HermesSessionRefusal`, and `BotFailure.unsupported` when the
    /// host imported no copy.
    @MainActor
    static func duplicate(key: String, profile: String, title: String,
                          on wire: any BotTransport) async throws -> (key: String, title: String?) {
        let export = try await wire.exportSession(key: key, profile: profile)
        let id = newID(at: Date())
        // An export can be megabytes, so it is read and the copy written off the main actor.
        let body = try await Task.detached(priority: .userInitiated) { try importBody(export, id: id, profile: profile) }.value
        let result: BotJSON
        do {
            result = try await wire.importSessions(body: body)
        } catch BotFailure.rejected(413) {
            throw TooLarge()
        }
        guard result["imported_ids"].list?.contains(.string(id)) == true else { throw BotFailure.unsupported }
        for attempt in 1...titleAttempts {
            do {
                let kept = try await wire.updateSession(.title(Self.title(title, attempt: attempt)), key: id, profile: profile)
                return (id, kept.flatMap { $0.isEmpty ? nil : $0 } ?? Self.title(title, attempt: attempt))
            } catch is HermesSessionRefusal {
                continue
            } catch {
                break
            }
        }
        return (id, nil)
    }

    /// The import of `export`'s copy as `id` into `profile`, refused as `TooLarge` past the
    /// host's limits.
    private static func importBody(_ export: Data, id: String, profile: String) throws -> Data {
        guard let copy = copy(of: try JSONDecoder().decode(BotJSON.self, from: export), id: id) else {
            throw BotFailure.unsupported
        }
        guard (copy["messages"].list?.count ?? 0) <= messageLimit else { throw TooLarge() }
        let body = try JSONEncoder().encode(BotJSON.object(["sessions": .array([copy]), "profile": .string(profile)]))
        guard body.count <= byteLimit else { throw TooLarge() }
        return body
    }

    /// `export` as a new session `id`: without its parent, compression lineage and derived
    /// timings, its messages without their row ids, untitled, and neither archived nor pinned.
    /// Nil for an export that is not a session with its messages.
    static func copy(of export: BotJSON, id: String) -> BotJSON? {
        guard var fields = export.fields, let messages = fields["messages"]?.list else { return nil }
        fields = fields.filter { key, _ in !key.hasPrefix("_lineage_") && key != "parent_session_id" && key != "timings" }
        fields["id"] = .string(id)
        fields["title"] = .null
        fields["archived"] = .bool(false)
        fields["pinned"] = .bool(false)
        fields["messages"] = .array(messages.map { message in .object((message.fields ?? [:]).filter { $0.key != "id" }) })
        return .object(fields)
    }

    /// A session id in the host's shape (`hermes_state_ids.py`), `YYYYMMDD_HHMMSS_<6 hex>`, at
    /// `date` in this phone's time zone.
    static func newID(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date) + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
    }

    /// The copy's title for one attempt: "<title> (copy)", then "(copy 2)" and on, with `title`
    /// cut so the whole fits the host's 100 characters.
    static func title(_ title: String, attempt: Int) -> String {
        let suffix = attempt == 1 ? " (copy)" : " (copy \(attempt))"
        let base = String(String.UnicodeScalarView(title.unicodeScalars.prefix(100 - suffix.unicodeScalars.count)))
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }
}

/// A Hermes session's parent, for its "Forked from" row and Fork From Here (#1051). A branch's
/// own row names its parent (`parent_session_id`) and stores `{"_branched_from": <parent>}` as its
/// `model_config`, which `session.branch` writes; a reset continuation or a compression segment
/// has a parent too, but no such mark, so it is no branch.
@MainActor enum HermesBranchParent {
    /// The parent's row when `key` of `profile` is a branch of a session the host still has;
    /// nil otherwise. Each read is the whole stored row, about 60 KB, so a chat reads it only
    /// when the row it opened from named a parent.
    static func row(of key: String, profile: String, on wire: any BotTransport) async throws -> HermesSessionRow? {
        guard let own = try await wire.sessionRow(key: key, profile: profile),
              let parent = own["parent_session_id"].text, !parent.isEmpty,
              own.modelConfigText("_branched_from") == parent,
              let row = try await wire.sessionRow(key: parent, profile: profile) else { return nil }
        let grandparent = row["parent_session_id"].text
        return HermesSessionRow(id: parent, title: row["title"].text, profile: profile,
                                parentSessionID: grandparent?.isEmpty == false ? grandparent : nil)
    }

    /// Whether a session's own row `own` holds its whole history as the host counts a branch
    /// (`_resume_lineage_ids`): it has no parent, or it is a branch, whose rows are a copy. Any
    /// other parent, a legacy compression segment or a reset continuation, puts that parent's
    /// rows first, and the session's own transcript pages never show them.
    static func standsAlone(_ own: BotJSON) -> Bool {
        (own["parent_session_id"].text ?? "").isEmpty || !(own.modelConfigText("_branched_from") ?? "").isEmpty
    }
}

extension BotJSON {
    /// `key` in a stored session row's `model_config`, which the host stores as a JSON string
    /// and may send as an object: `_branched_from` on a branch, `_delegate_from` on a subagent.
    func modelConfigText(_ key: String) -> String? {
        let config = self["model_config"]
        let object = config.text.flatMap { try? JSONDecoder().decode(BotJSON.self, from: Data($0.utf8)) } ?? config
        return object[key].text
    }
}

/// Deletes a Hermes session the way #1048 decided: through `session.delete`, never REST `DELETE`,
/// so a runtime that holds the session blocks it instead of losing that work.
///
/// The host refuses (4023) while any runtime in its process holds the session, and keeps a
/// runtime after the screen that attached it leaves. So this phone's own runtimes on the session
/// (`BotTransport.attachedRuntimes`, as `session.active_list` still lists them) are closed first
/// when idle, and a busy one refuses the delete before anything is sent. A 4023 after that is a
/// runtime this phone did not attach: another app has the session open, and nothing changed.
/// The host can't say who else views a runtime this phone attached, so closing one ends it for
/// them too.
@MainActor enum HermesSessionDeletion {
    enum Outcome: Equatable {
        case deleted
        /// A reply runs, or waits on an answer, in a runtime this phone attached.
        case busyHere
        /// The host refused (4023): a runtime this phone did not attach holds the session.
        case openElsewhere
    }

    static func delete(key: String, profile: String, on wire: any BotTransport) async throws -> Outcome {
        // An older host without the live list still refuses a held session with 4023.
        let live = (try? await wire.call(.sessionActiveList))?["sessions"].list ?? []
        let attached = wire.attachedRuntimes
        let own = live.filter { $0["session_key"].text == key && attached.contains($0["id"].text ?? "") }
        if own.contains(where: { !SessionRowAttentionState.hermesStates([$0]).isEmpty }) { return .busyHere }
        for runtime in own.compactMap({ $0["id"].text }) {
            _ = try await wire.call(.sessionClose(runtime: runtime))
        }
        do {
            _ = try await wire.call(.sessionDelete(profile: profile, storedKey: key))
        } catch BotFailure.rejected(4023) {
            return .openElsewhere
        }
        return .deleted
    }

    /// What the list and the Archived screen say when the host kept the session.
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .deleted: return nil
        case .busyHere: return String(localized: "This session is still replying here. Stop the reply first, then delete it.")
        case .openElsewhere:
            return String(localized: "This session is open in another app, so nothing was deleted. Close it there, then try again.")
        }
    }
}
