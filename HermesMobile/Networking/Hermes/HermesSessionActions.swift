import Foundation

struct HermesSessionRefusal: LocalizedError, Equatable {
    struct Entry: Equatable, Sendable {
        let index: Int
        let sessionID: String?
        let reason: String
    }

    let message: String
    var entries: [Entry] = []
    var errorDescription: String? { message }
}

enum HermesSessionFenceRefusal: LocalizedError, Equatable {
    case changed
    case busy
    case updateRequired
    case refused

    init?(detail: String?) {
        switch detail {
        case "revision_conflict"?, "stale_generation"?, "admission_conflict"?: self = .changed
        case "session_busy"?: self = .busy
        case "mutation_identity_required"?: self = .updateRequired
        case let detail? where detail.hasPrefix("client_upgrade_required"): self = .updateRequired
        case "not_found"?, "permission_denied"?: self = .refused
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .changed: return String(localized: "This session changed on the server. Try again.")
        case .busy: return String(localized: "This session is busy. Try again when it finishes.")
        case .updateRequired: return String(localized: "Update Hermex to change sessions on this server.")
        case .refused:
            return String(localized: "The server refused to change this session. If an earlier Hermex 2.0 build created it, duplicate it and change the copy.")
        }
    }
}

enum HermesSessionDuplication {
    static let messageLimit = 10_000
    static let byteLimit = 5 * 1024 * 1024
    static let titleAttempts = 10

    struct TooLarge: LocalizedError, Equatable {
        var errorDescription: String? { String(localized: "This session is too large to duplicate.") }
    }

    @MainActor
    static func duplicate(key: String, profile: String, title: String,
                          on wire: any BotTransport) async throws -> (key: String, title: String?) {
        let export = try await wire.exportSession(key: key, profile: profile)
        let id = newID(at: Date())
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

    private static func importBody(_ export: Data, id: String, profile: String) throws -> Data {
        guard let copy = copy(of: try JSONDecoder().decode(BotJSON.self, from: export), id: id) else {
            throw BotFailure.unsupported
        }
        guard (copy["messages"].list?.count ?? 0) <= messageLimit else { throw TooLarge() }
        let body = try JSONEncoder().encode(BotJSON.object(["sessions": .array([copy]), "profile": .string(profile)]))
        guard body.count <= byteLimit else { throw TooLarge() }
        return body
    }

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

    static func newID(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date) + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
    }

    static func title(_ title: String, attempt: Int) -> String {
        let suffix = attempt == 1 ? " (copy)" : " (copy \(attempt))"
        let base = String(String.UnicodeScalarView(title.unicodeScalars.prefix(100 - suffix.unicodeScalars.count)))
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }
}

@MainActor enum HermesBranchParent {
    static func row(of key: String, profile: String, on wire: any BotTransport) async throws -> HermesSessionRow? {
        guard let own = try await wire.sessionRow(key: key, profile: profile),
              let parent = own["parent_session_id"].text, !parent.isEmpty,
              own.modelConfigText("_branched_from") == parent,
              let row = try await wire.sessionRow(key: parent, profile: profile) else { return nil }
        let grandparent = row["parent_session_id"].text
        return HermesSessionRow(id: parent, title: row["title"].text, profile: profile,
                                parentSessionID: grandparent?.isEmpty == false ? grandparent : nil)
    }

    static func standsAlone(_ own: BotJSON) -> Bool {
        (own["parent_session_id"].text ?? "").isEmpty || !(own.modelConfigText("_branched_from") ?? "").isEmpty
    }
}

extension BotJSON {
    func modelConfigText(_ key: String) -> String? {
        let config = self["model_config"]
        let object = config.text.flatMap { try? JSONDecoder().decode(BotJSON.self, from: Data($0.utf8)) } ?? config
        return object[key].text
    }
}

@MainActor enum HermesSessionDeletion {
    enum Outcome: Equatable {
        case deleted
        case busyHere
        case openElsewhere
    }

    static func delete(key: String, profile: String, on wire: any BotTransport) async throws -> Outcome {
        if wire.speaksCanonicalProtocol {
            do { _ = try await wire.mutateStoredSession(profile: profile, key: key, .delete) }
            catch BotSettingFailure.rejected(_, "session_busy") { return .busyHere }
            return .deleted
        }
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

    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .deleted: return nil
        case .busyHere: return String(localized: "This session is still replying here. Stop the reply first, then delete it.")
        case .openElsewhere:
            return String(localized: "This session is open in another app, so nothing was deleted. Close it there, then try again.")
        }
    }
}
