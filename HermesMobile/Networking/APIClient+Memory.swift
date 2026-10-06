import Foundation

/// What the Memory screen calls, so one screen runs on either kind of server: a webui
/// server's `/api/memory` (`APIClient`) or one Hermes Profile's files (`HermesMemoryClient`,
/// #1073). `memoryFeatures` says what the screen adds for the server.
protocol MemoryDataClient: Sendable {
    var memoryFeatures: MemoryFeatures { get }
    func memory() async throws -> MemoryResponse
    /// Saves `content` to `section`. `loaded` is the section's text when its editor opened: a
    /// server that checks for changes made meanwhile throws `MemoryConflict` instead of writing,
    /// unless it already holds `content`, as after a save whose reply was lost.
    func saveMemory(section: MemorySection, content: String, loaded: String) async throws -> MemoryWriteResponse
}

/// What the Memory screen adds for one server. A Hermes host's sections (#1073) reach the
/// agent at its next session, which the editor says; they come with no modified times and no
/// project context, so the screen shows neither.
struct MemoryFeatures: Equatable, Sendable {
    let editsApplyNextSession: Bool

    static let webui = MemoryFeatures(editsApplyNextSession: false)
    static let hermes = MemoryFeatures(editsApplyNextSession: true)
}

extension APIClient: MemoryDataClient {
    nonisolated var memoryFeatures: MemoryFeatures { .webui }

    func memory() async throws -> MemoryResponse {
        try await send(endpoint: .memory, method: "GET")
    }

    func writeMemory(section: MemorySection, content: String) async throws -> MemoryWriteResponse {
        try await send(
            endpoint: .memoryWrite,
            method: "POST",
            body: MemoryWriteRequest(section: section, content: content)
        )
    }

    /// webui writes the editor's text as it is, without a change check.
    func saveMemory(section: MemorySection, content: String, loaded _: String) async throws -> MemoryWriteResponse {
        try await writeMemory(section: section, content: content)
    }
}

private struct MemoryWriteRequest: Encodable {
    let section: MemorySection
    let content: String
}

/// The Memory screen's client on a Hermes host (#1073), for one Profile: its notes and user
/// profile are `memories/MEMORY.md` and `USER.md` in the Profile's folder, read and written
/// through the host's file routes, and its soul is `/api/profiles/{name}/soul`. The folder is
/// read from the Profile's `profiles.list` row on every load and save, and is the only host
/// path these routes are ever sent; it is never shown, logged or kept. The host's config says
/// which sections are on and their limits, and only its `memory` section is decoded.
///
/// A save re-reads the file first and refuses with `MemoryConflict` when it no longer matches
/// what the editor opened with, unless it already holds what is being saved: a retry after a
/// save that landed but whose reply or refresh was lost overwrites nothing. The agent can
/// still write between that read and the write, which takes no lock: a small window accepted
/// to use the host's public file routes.
@MainActor final class HermesMemoryClient: MemoryDataClient {
    nonisolated var memoryFeatures: MemoryFeatures { .hermes }
    let profile: String
    private let http: HermesConnection

    /// `profile`'s memory on `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL, profile: String) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server), profile: profile)
    }

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

    /// The sections the host's config turns on, with their limits, and the soul. A missing
    /// file is an empty one. A file the host could only preview (over 512 KiB) or that isn't
    /// text is shown read-only.
    func memory() async throws -> MemoryResponse {
        async let folderRead = memoriesFolder()
        async let configRead = memoryConfig()
        async let soulRead = soul()
        let (folder, config, soul) = try await (folderRead, configRead, soulRead)
        async let notesRead = read(folder + "/MEMORY.md", if: config.memoryEnabled)
        async let userRead = read(folder + "/USER.md", if: config.userProfileEnabled)
        let (notes, user) = try await (notesRead, userRead)

        var response = MemoryResponse(memory: notes?.text, user: user?.text, soul: soul)
        response.hiddenSections = Set([config.memoryEnabled ? nil : MemorySection.memory,
                                       config.userProfileEnabled ? nil : .user].compactMap { $0 })
        response.characterLimits = [.memory: config.memoryLimit, .user: config.userLimit]
        response.readOnlySections = Set([notes?.isEditable == false ? MemorySection.memory : nil,
                                         user?.isEditable == false ? .user : nil].compactMap { $0 })
        return response
    }

    /// Notes and the user profile are written in the agent's own format
    /// (`MemoryCanonicalizer`), then read back to confirm. Writing needs the `memories` folder,
    /// which a Profile normally has; one that doesn't is created once and the write retried.
    /// The soul is written as it is, with the same check first.
    func saveMemory(section: MemorySection, content: String, loaded: String) async throws -> MemoryWriteResponse {
        switch section {
        case .soul:
            let current = try await soul()
            guard current == loaded || current == content else { throw MemoryConflict() }
            _ = try accepted(try await reply(.setProfileSoul(name: profile, content: content)))
        case .memory, .user:
            let folder = try await memoriesFolder()
            let path = folder + (section == .user ? "/USER.md" : "/MEMORY.md")
            let text = MemoryCanonicalizer.canonical(content)
            let current = try await read(path)
            guard current.isEditable, current.text == loaded || current.text == text else { throw MemoryConflict() }
            var written = try await reply(.fsWriteText(path: path, content: text))
            if written.status == 400, Self.detail(written.body) == "Parent directory does not exist" {
                _ = try accepted(try await reply(.filesMkdir(path: folder)))
                written = try await reply(.fsWriteText(path: path, content: text))
            }
            _ = try accepted(written)
            guard try await read(path).text == text else { throw MemoryConflict() }
        }
        return MemoryWriteResponse(saved: section)
    }

    // MARK: - Reads

    /// The Profile's `memories` folder: its `profiles.list` row's `path`, the Profile's home.
    private func memoriesFolder() async throws -> String {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        let rows = try await client.call(.profilesList(includeSessions: false))["profiles"].list ?? []
        guard let folder = Self.memoriesFolder(in: rows, profile: profile) else { throw HermesMemoryProfileMissing() }
        return folder
    }

    /// `profile`'s row's `path` with `/memories` appended; nil when no row names it or its
    /// path is empty.
    static func memoriesFolder(in rows: [BotJSON], profile: String) -> String? {
        guard let path = rows.first(where: { $0["name"].text == profile })?["path"].text,
              !path.isEmpty, !path.contains("\0") else { return nil }
        return (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/memories"
    }

    private func memoryConfig() async throws -> HermesMemoryConfig {
        let body = try accepted(try await reply(.config(profile: profile)))
        do { return try JSONDecoder().decode(HermesMemoryConfigBody.self, from: body).memory ?? HermesMemoryConfig() } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private func soul() async throws -> String {
        let body = try accepted(try await reply(.profileSoul(name: profile)))
        guard let content = Self.json(body)?["content"].text else { throw APIError.decoding(underlying: HermesMemoryUnreadable()) }
        return content
    }

    /// One file's text. A file the host doesn't have (404) reads as empty.
    private func read(_ path: String) async throws -> HermesMemoryFile {
        let answer = try await reply(.fsReadText(path: path))
        guard answer.status != 404 else { return HermesMemoryFile(text: "", isEditable: true) }
        let file = Self.json(try accepted(answer))
        guard let text = file?["text"].text else { throw APIError.decoding(underlying: HermesMemoryUnreadable()) }
        return HermesMemoryFile(text: text, isEditable: file?["truncated"].flag != true && file?["binary"].flag != true)
    }

    /// A section's file when the host's config turns the section on; nil, unread, when not.
    private func read(_ path: String, if enabled: Bool) async throws -> HermesMemoryFile? {
        enabled ? try await read(path) : nil
    }

    // MARK: - Wire

    /// A dropped request reads as the webui's network failure, so a cancellation is
    /// recognised as one.
    private func reply(_ rest: HermesREST) async throws -> (body: Data, status: Int) {
        do { return try await http.reply(rest) } catch let error as URLError {
            throw APIError.network(underlying: error)
        }
    }

    /// A 2xx reply's body. A 4xx the host explains in `detail`, a 403 included (a file it
    /// can't write, or a path outside a locked files root), reads as that reason, unless the
    /// reason names a path. A 403 or 502-504 with no reason is the proxy or tunnel in front
    /// of it. Anything else is `APIError.http`, without its body, which can carry a path.
    private func accepted(_ reply: (body: Data, status: Int)) throws -> Data {
        switch reply.status {
        case 200..<300: return reply.body
        case 400..<500:
            if let detail = Self.detail(reply.body), !detail.contains("/"), !detail.contains("\\") {
                throw HermesMemoryRefusal(detail: detail)
            }
            if reply.status == 403 { throw BotFailure.rejected(403) }
        case 502...504, 520...530: throw BotFailure.rejected(reply.status)
        default: break
        }
        throw APIError.http(statusCode: reply.status, body: nil)
    }

    private static func detail(_ body: Data) -> String? {
        guard let detail = json(body)?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return nil }
        return detail
    }

    private static func json(_ body: Data) -> BotJSON? {
        try? JSONDecoder().decode(BotJSON.self, from: body)
    }
}

/// A memory request a Hermes host refused with its reason (`{detail}`), such as a file it
/// can't write.
struct HermesMemoryRefusal: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { String(localized: "The server rejected the request: \(detail)") }
}

/// The Profile the Memory screen opened on is no longer in the host's `profiles.list`, so
/// there is no folder to read or write.
struct HermesMemoryProfileMissing: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "This Profile is no longer on the server.") }
}

private struct HermesMemoryUnreadable: Error {}

private struct HermesMemoryFile {
    let text: String
    let isEditable: Bool
}

/// `GET /api/config`, whole and unredacted (credentials included), of which only `memory`
/// is decoded. A `memory` that isn't an object reads as the defaults, as the agent reads it.
private struct HermesMemoryConfigBody: Decodable {
    let memory: HermesMemoryConfig?

    enum CodingKeys: String, CodingKey { case memory }

    init(from decoder: Decoder) throws {
        memory = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(HermesMemoryConfig.self, forKey: .memory)
    }
}

/// The host's `memory` config, read as the agent reads it: a flag is on unless set to a false
/// value (`false`, `0`, or a string outside `1`, `true`, `yes`, `on`), and a limit is a whole
/// number, else the host's default.
private struct HermesMemoryConfig: Decodable {
    var memoryEnabled = true
    var userProfileEnabled = true
    var memoryLimit = 2200
    var userLimit = 1375

    enum CodingKeys: String, CodingKey {
        case memoryEnabled = "memory_enabled", userProfileEnabled = "user_profile_enabled"
        case memoryLimit = "memory_char_limit", userLimit = "user_char_limit"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryEnabled = Self.flag(container, .memoryEnabled)
        userProfileEnabled = Self.flag(container, .userProfileEnabled)
        memoryLimit = container.decodeLossyIntIfPresent(forKey: .memoryLimit) ?? memoryLimit
        userLimit = container.decodeLossyIntIfPresent(forKey: .userLimit) ?? userLimit
    }

    /// `utils.is_truthy_value(value, default=True)`.
    private static func flag(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return true
    }
}
