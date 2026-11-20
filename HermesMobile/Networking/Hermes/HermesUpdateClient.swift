import Foundation

@MainActor final class HermesUpdateClient {
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func check(force: Bool) async throws -> HermesUpdateCheck {
        HermesUpdateCheck(try Self.json(try await http.data(.updateCheck(force: force))))
    }

    func start() async throws -> HermesUpdateStart {
        let reply = try Self.json(try await http.data(.updateApply))
        guard reply["ok"].flag == true else {
            return .refused(error: reply["error"].text, message: reply["message"].text, command: reply["update_command"].text)
        }
        return .started(pid: reply["pid"].integer)
    }

    func status() async throws -> HermesUpdateStatus {
        HermesUpdateStatus(try Self.json(try await http.data(.updateStatus)))
    }

    func receipt() async throws -> HermesUpdateReceipt? {
        do {
            let reply = try Self.json(try await http.data(.updateReceipt))
            return HermesUpdateReceipt(reply["summary"]) ?? HermesUpdateReceipt(reply["receipt"])
        } catch BotFailure.rejected(404) { return nil }
    }

    func health() async throws -> String? {
        try Self.json(try await http.publicData(.health))["version"].text
    }

    private static func json(_ data: Data) throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: data)
    }
}

struct HermesUpdateCheck: Equatable {
    let installMethod: String?
    let currentVersion: String?
    let behind: Int?
    let updateAvailable: Bool
    let canApply: Bool
    let updateCommand: String?
    let message: String?
    let offer: Offer

    enum Offer: Equatable {
        case update, nothing
        case moveBack
        case held
    }

    init(installMethod: String? = "git", currentVersion: String? = nil, behind: Int?, updateAvailable: Bool,
         canApply: Bool = true, updateCommand: String? = "hermes update", message: String? = nil,
         offer: Offer? = nil) {
        self.installMethod = installMethod; self.currentVersion = currentVersion; self.behind = behind
        self.updateAvailable = updateAvailable; self.canApply = canApply
        self.updateCommand = updateCommand; self.message = message
        self.offer = offer ?? (updateAvailable ? .update : .nothing)
    }

    init(_ json: BotJSON) {
        self.init(installMethod: json["install_method"].text, currentVersion: json["current_version"].text,
                  behind: json["behind"].integer, updateAvailable: json["update_available"].flag ?? false,
                  canApply: json["can_apply"].flag ?? false, updateCommand: json["update_command"].text,
                  message: json["message"].text,
                  offer: json["rollback_to"].text != nil ? .moveBack : json["held"].text != nil ? .held : nil)
    }

    var hostCommand: String? {
        installMethod == "managed-runtime" ? nil : updateCommand.flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum HermesUpdateStart: Equatable {
    case started(pid: Int?)
    case refused(error: String?, message: String?, command: String?)

    var hostCommand: String? {
        guard case .refused(let error, _, let command) = self, error != "dashboard_update_managed_externally",
              let command, !command.isEmpty else { return nil }
        return command
    }
}

struct HermesUpdateReceipt: Equatable {
    enum Outcome: Equatable {
        case running, success, partial, failed, refused
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
    let startedAt: String?
    let postVersion: String?

    init(outcome: Outcome?, startedAt: String?, postVersion: String? = nil) {
        self.outcome = outcome; self.startedAt = startedAt; self.postVersion = postVersion
    }

    init?(_ json: BotJSON) {
        guard json.fields != nil else { return nil }
        self.init(outcome: json["outcome"].text.map(Outcome.init), startedAt: json["started_at"].text,
                  postVersion: json["post_version"].text ?? json["post_update"]["version"].text)
    }
}

struct HermesUpdateStatus: Equatable {
    let running: Bool
    let exitCode: Int?
    let pid: Int?
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
