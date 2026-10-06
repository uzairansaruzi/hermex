import Foundation

/// Settings' update rows on a Hermes host (#1075): the host's update check, `hermes update`
/// started from the phone, and the reads that follow it through the dashboard's restart. The
/// signed-in reads go over the sign-in the server's Bot screens share, which signs in again on
/// the restarted dashboard's first 401 (its session key is new); `health` is public, so it
/// answers while no sign-in can. Every reply decodes tolerantly: a field the host omits or
/// renames reads as unknown.
@MainActor final class HermesUpdateClient {
    private let http: HermesConnection

    /// Updates for `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func check(force: Bool) async throws -> HermesUpdateCheck {
        HermesUpdateCheck(try Self.json(try await http.data(.updateCheck(force: force))))
    }

    /// Starts the update, or joins the one already running. The host refuses an install that
    /// can't update itself in place with 200 and `ok: false`; any other status throws.
    func start() async throws -> HermesUpdateStart {
        let reply = try Self.json(try await http.data(.updateApply))
        guard reply["ok"].flag == true else {
            return .refused(error: reply["error"].text, message: reply["message"].text, command: reply["update_command"].text)
        }
        return .started(pid: reply["pid"].integer)
    }

    /// The update action's status. A host without the action answers 404, thrown as
    /// `BotFailure.rejected(404)`.
    func status() async throws -> HermesUpdateStatus {
        HermesUpdateStatus(try Self.json(try await http.data(.updateStatus)))
    }

    /// The latest receipt's summary, or nil when no update has run (404).
    func receipt() async throws -> HermesUpdateReceipt? {
        do {
            let reply = try Self.json(try await http.data(.updateReceipt))
            return HermesUpdateReceipt(reply["summary"]) ?? HermesUpdateReceipt(reply["receipt"])
        } catch BotFailure.rejected(404) { return nil }
    }

    /// The release the running dashboard reports, read without signing in; nil when it
    /// answers without one. Throws when it doesn't answer.
    func health() async throws -> String? {
        try Self.json(try await http.publicData(.health))["version"].text
    }

    private static func json(_ data: Data) throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: data)
    }
}

/// `GET /api/hermes/update/check`: whether the install is behind, and whether the dashboard
/// can update it in place (`can_apply`, git installs only). Others carry the command to run on
/// the host. A containerised host answers `managed-runtime`, whose `update_command` is a
/// sentence rather than a command.
struct HermesUpdateCheck: Equatable {
    let installMethod: String?
    /// The host's release with any build suffix, such as `0.21.5+6146.g46904a3`.
    let currentVersion: String?
    /// Commits behind: 0 when current, -1 for an unknown count, nil when the check couldn't run.
    let behind: Int?
    let updateAvailable: Bool
    let canApply: Bool
    let updateCommand: String?
    /// The host's guidance, such as why the check couldn't run.
    let message: String?

    init(installMethod: String? = "git", currentVersion: String? = nil, behind: Int?, updateAvailable: Bool,
         canApply: Bool = true, updateCommand: String? = "hermes update", message: String? = nil) {
        self.installMethod = installMethod; self.currentVersion = currentVersion; self.behind = behind
        self.updateAvailable = updateAvailable; self.canApply = canApply
        self.updateCommand = updateCommand; self.message = message
    }

    init(_ json: BotJSON) {
        self.init(installMethod: json["install_method"].text, currentVersion: json["current_version"].text,
                  behind: json["behind"].integer, updateAvailable: json["update_available"].flag ?? false,
                  canApply: json["can_apply"].flag ?? false, updateCommand: json["update_command"].text,
                  message: json["message"].text)
    }

    /// The command for the user to run on the host, or nil when there is none to copy.
    var hostCommand: String? {
        installMethod == "managed-runtime" ? nil : updateCommand.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// `POST /api/hermes/update`'s answer.
enum HermesUpdateStart: Equatable {
    /// The update started, or was already running; `pid` is its process on the host.
    case started(pid: Int?)
    /// The host can't update this install in place: its reason and the command to run there.
    case refused(error: String?, message: String?, command: String?)

    /// The refused command for the user to copy, or nil when there is none: a containerised
    /// host's is a sentence.
    var hostCommand: String? {
        guard case .refused(let error, _, let command) = self, error != "dashboard_update_managed_externally",
              let command, !command.isEmpty else { return nil }
        return command
    }
}

/// The summary of an update receipt, the host's durable record of its latest `hermes update`,
/// written when the run finishes, including refused and failed runs, and kept across the
/// dashboard's restart. A run in progress is not in it until it finishes.
struct HermesUpdateReceipt: Equatable {
    enum Outcome: Equatable {
        case running, success, partial, failed, refused
        /// A value this build doesn't know, read as a failure.
        case other(String)

        init(_ value: String) {
            switch value {
            case "running": self = .running
            case "success": self = .success
            case "partial": self = .partial
            case "failed": self = .failed
            case "refused": self = .refused
            default: self = .other(value)
            }
        }
    }

    let outcome: Outcome?
    /// When the run started, by the host's clock; tells one run's receipt from the next.
    let startedAt: String?
    /// The release the update installed; nil when the host couldn't read it.
    let postVersion: String?

    init(outcome: Outcome?, startedAt: String?, postVersion: String? = nil) {
        self.outcome = outcome; self.startedAt = startedAt; self.postVersion = postVersion
    }

    /// Reads the compact summary (`post_version`) or the full receipt (`post_update.version`);
    /// nil for anything that isn't an object.
    init?(_ json: BotJSON) {
        guard json.fields != nil else { return nil }
        self.init(outcome: json["outcome"].text.map(Outcome.init), startedAt: json["started_at"].text,
                  postVersion: json["post_version"].text ?? json["post_update"]["version"].text)
    }
}

/// `GET /api/actions/hermes-update/status`. After the dashboard restarts it no longer tracks
/// the process: `running` is false, `pid` is null, and `exit_code` comes from the log's
/// completion marker or from the latest receipt, which can be an earlier run's.
struct HermesUpdateStatus: Equatable {
    let running: Bool
    let exitCode: Int?
    /// The update process while this dashboard still tracks it; nil after a restart.
    let pid: Int?
    /// The tail of the host's update log.
    let lines: [String]
    let receipt: HermesUpdateReceipt?

    init(running: Bool, exitCode: Int? = nil, pid: Int? = nil, lines: [String] = [], receipt: HermesUpdateReceipt? = nil) {
        self.running = running; self.exitCode = exitCode; self.pid = pid; self.lines = lines; self.receipt = receipt
    }

    init(_ json: BotJSON) {
        self.init(running: json["running"].flag ?? false, exitCode: json["exit_code"].integer, pid: json["pid"].integer,
                  lines: json["lines"].list?.compactMap(\.text) ?? [], receipt: HermesUpdateReceipt(json["receipt"]))
    }
}
