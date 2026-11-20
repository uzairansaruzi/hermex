import Foundation

protocol MemoryDataClient: Sendable {
    var memoryFeatures: MemoryFeatures { get }
    func memory() async throws -> MemoryResponse
    func saveMemory(section: MemorySection, content: String, loaded: String) async throws -> MemoryWriteResponse
}

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

    func saveMemory(section: MemorySection, content: String, loaded _: String) async throws -> MemoryWriteResponse {
        try await writeMemory(section: section, content: content)
    }
}

private struct MemoryWriteRequest: Encodable {
    let section: MemorySection
    let content: String
}

@MainActor final class HermesMemoryClient: MemoryDataClient {
    nonisolated var memoryFeatures: MemoryFeatures { .hermes }
    let profile: String
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL, profile: String) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server), profile: profile)
    }

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

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
            _ = try accepted(try await reply(.filesUpload(path: path, text: text)))
            guard try await read(path).text == text else { throw MemoryConflict() }
        }
        return MemoryWriteResponse(saved: section)
    }

    private func memoriesFolder() async throws -> String {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        let rows = try await client.call(.profilesList(includeSessions: false))["profiles"].list ?? []
        guard let folder = Self.memoriesFolder(in: rows, profile: profile) else { throw HermesMemoryProfileMissing() }
        return folder
    }

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

    private static let editableBytes = 512 * 1024

    private func read(_ path: String) async throws -> HermesMemoryFile {
        let answer = try await reply(.filesRead(path: path))
        guard answer.status != 404 else { return HermesMemoryFile(text: "", isEditable: true) }
        guard let url = Self.json(try accepted(answer))?["data_url"].text, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw APIError.decoding(underlying: HermesMemoryUnreadable())
        }
        if data.count <= Self.editableBytes, let text = String(bytes: data, encoding: .utf8) {
            return HermesMemoryFile(text: text, isEditable: true)
        }
        return HermesMemoryFile(text: String(decoding: data.prefix(Self.editableBytes), as: UTF8.self), isEditable: false)
    }

    private func read(_ path: String, if enabled: Bool) async throws -> HermesMemoryFile? {
        enabled ? try await read(path) : nil
    }

    private func reply(_ rest: HermesREST) async throws -> (body: Data, status: Int) {
        do { return try await http.reply(rest) } catch let error as URLError {
            throw APIError.network(underlying: error)
        }
    }

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

struct HermesMemoryRefusal: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { String(localized: "The server rejected the request: \(detail)") }
}

struct HermesMemoryProfileMissing: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "This Profile is no longer on the server.") }
}

private struct HermesMemoryUnreadable: Error {}

private struct HermesMemoryFile {
    let text: String
    let isEditable: Bool
}

private struct HermesMemoryConfigBody: Decodable {
    let memory: HermesMemoryConfig?

    enum CodingKeys: String, CodingKey { case memory }

    init(from decoder: Decoder) throws {
        memory = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(HermesMemoryConfig.self, forKey: .memory)
    }
}

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

    private static func flag(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return true
    }
}
