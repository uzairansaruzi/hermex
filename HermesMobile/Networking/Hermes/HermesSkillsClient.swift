import Foundation

/// The Skills screens' client on a Hermes host (#1069): one Profile's skills under `/api/skills`,
/// over the sign-in, headers and cookie jar the server's Bot screens share. Every read and the
/// toggle name that Profile. The host sends no tags or related skills. A skill's linked files
/// (#1070) are the other files in its SKILL.md's folder, read through `/api/fs/*`, which accepts
/// any host path: every path it is asked for is built from that folder and stays inside it. The
/// folder is an opaque handle, never shown, logged or persisted. A refusal the host explains,
/// such as a skill that is gone, reads as its `detail`.
@MainActor final class HermesSkillsClient: SkillsDataClient {
    nonisolated var skillsFeatures: SkillsFeatures { .hermes }
    let profile: String
    private let http: HermesConnection
    /// Each read skill's folder on the host, from its SKILL.md's path, for opening its files.
    private var folders: [String: String] = [:]

    /// `profile`'s skills on `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL, profile: String) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server), profile: profile)
    }

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

    func skills() async throws -> SkillsResponse {
        SkillsResponse(skills: try Self.skills(try await send(.skills(profile: profile))))
    }

    /// SKILL.md with its folder's other files as `linkedFiles`, or, when `file` names one of them,
    /// that file's text. A `file` that would leave the folder is refused before any request.
    func skillContent(name: String, file: String?) async throws -> SkillDetailResponse {
        guard let file else {
            let detail = try await skillMd(name)
            guard let folder = folders[name] else { return detail }
            let files = await linkedFiles(in: folder)
            return SkillDetailResponse(name: detail.name, content: detail.content, linkedFiles: files.isEmpty ? nil : files)
        }
        guard file.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ Self.isName(String($0)) })
        else { throw BotArtifactFailure.unavailable }
        if folders[name] == nil { _ = try await skillMd(name) }
        guard let folder = folders[name] else { throw BotArtifactFailure.unavailable }
        let reply = try Self.decode(BotJSON.self, try await send(.fsReadText(path: folder + "/" + file)))
        let isBinary = reply["binary"].flag == true
        return SkillDetailResponse(name: name, content: isBinary ? nil : reply["text"].text, linkedFiles: nil,
                                   isBinary: isBinary, isTruncated: reply["truncated"].flag == true)
    }

    func toggleSkill(name: String, enabled: Bool) async throws -> ToggleSkillResponse {
        try Self.decode(ToggleSkillResponse.self, try await send(.setSkill(name: name, enabled: enabled, profile: profile)))
    }

    /// `GET /api/skills`'s bare array as the app's skills: each one `disabled` when the host lists
    /// it not `enabled`, and a row without a name left out. A reply that is not an array is a
    /// failed read, not an empty Profile. The Tasks editor reads its skills through it too
    /// (`HermesCronClient.cronSkills`).
    static func skills(_ body: Data) throws -> [SkillSummary] {
        try decode([BotJSON].self, body).compactMap { row in
            guard let name = row["name"].text, !name.isEmpty else { return nil }
            return SkillSummary(name: name, category: row["category"].text, description: row["description"].text,
                                path: nil, disabled: row["enabled"].flag.map { !$0 })
        }
    }

    /// `name`'s SKILL.md, remembering its folder: the host path it returns without `/SKILL.md`
    /// (or a Windows host's `\SKILL.md`), or none when it returns no such path.
    private func skillMd(_ name: String) async throws -> SkillDetailResponse {
        let body = try await send(.skillContent(name: name, profile: profile))
        let detail = try Self.decode(SkillDetailResponse.self, body)
        let path = (try? JSONDecoder().decode(BotJSON.self, from: body))?["path"].text ?? ""
        let suffix = ["/SKILL.md", "\\SKILL.md"].first { path.count > $0.count && path.hasSuffix($0) }
        folders[name] = suffix.map { String(path.dropLast($0.count)) }
        return detail
    }

    /// The files in `folder` and in each folder directly inside it, as sorted paths relative to it,
    /// without SKILL.md or hidden files. A listing the host can't read, such as its 200
    /// `{entries: [], error}`, adds none, so the skill still opens.
    private func linkedFiles(in folder: String) async -> [String] {
        let top = await entries(in: folder)
        let nested = await withTaskGroup(of: [String].self) { group in
            for entry in top where entry.isDirectory {
                group.addTask {
                    await self.entries(in: folder + "/" + entry.name).filter { !$0.isDirectory }.map { entry.name + "/" + $0.name }
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return (top.filter { !$0.isDirectory && $0.name != "SKILL.md" }.map(\.name) + nested).sorted()
    }

    /// One folder's visible entries by name. The listing's own `path` is resolved on the host, so
    /// it is never read: a child's path is always its folder's plus its name.
    private func entries(in folder: String) async -> [(name: String, isDirectory: Bool)] {
        guard let body = try? await send(.fsList(path: folder)),
              let rows = (try? JSONDecoder().decode(BotJSON.self, from: body))?["entries"].list else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"].text, Self.isName(name), !name.hasPrefix(".") else { return nil }
            return (name, row["isDirectory"].flag == true)
        }
    }

    /// One file or folder name, so a path joined from names never leaves its folder: not empty,
    /// `.` or `..`, and without a separator or NUL.
    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
    }

    /// One request's body, or the failure the host's status means (`HermesCronClient.accepted`).
    /// A dropped request reads as the webui's network failure, so a cancellation is recognised as one.
    private func send(_ rest: HermesREST) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        return try HermesCronClient.accepted(reply)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: body) } catch { throw APIError.decoding(underlying: error) }
    }
}
