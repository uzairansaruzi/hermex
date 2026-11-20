import Foundation

enum SessionExportFormat: String, CaseIterable {
    case html
    case json

    var fileExtension: String { rawValue }
}

struct SessionExportFile: Equatable {
    let data: Data
    let filename: String
}

extension APIClient {
    func exportSession(
        id: String,
        format: SessionExportFormat,
        fallbackTitle: String? = nil
    ) async throws -> SessionExportFile {
        let (data, response) = try await sendDataReturningResponse(
            endpoint: .exportSession(sessionID: id, format: format),
            method: "GET",
            encodedBody: nil,
            accept: "*/*"
        )

        let filename = SessionExportFile.filename(
            contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
            fallbackTitle: fallbackTitle,
            sessionID: id,
            format: format
        )

        return SessionExportFile(data: data, filename: filename)
    }
}

extension SessionExportFile {
    static func filename(
        contentDisposition: String?,
        fallbackTitle: String?,
        sessionID: String,
        format: SessionExportFormat
    ) -> String {
        if let headerName = filenameParameter(in: contentDisposition),
           let sanitized = sanitizedFilename(headerName) {
            return sanitized
        }

        if let title = fallbackTitle,
           let sanitizedTitle = sanitizedFilenameStem(title) {
            return "\(sanitizedTitle).\(format.fileExtension)"
        }

        let sanitizedID = sanitizedFilenameStem(sessionID) ?? "session"
        return "hermes-\(sanitizedID).\(format.fileExtension)"
    }

    private static func filenameParameter(in contentDisposition: String?) -> String? {
        guard let contentDisposition else { return nil }

        for parameter in contentDisposition.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "filename" else { continue }

            var value = trimmed[trimmed.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }

        return nil
    }

    private static func sanitizedFilename(_ raw: String) -> String? {
        let lastComponent = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? raw

        let cleaned = replacingUnsafeFilenameCharacters(in: lastComponent)
        guard !cleaned.isEmpty, cleaned != "." , cleaned != ".." else { return nil }
        return cleaned
    }

    private static func sanitizedFilenameStem(_ raw: String) -> String? {
        let cleaned = replacingUnsafeFilenameCharacters(in: raw)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    private static func replacingUnsafeFilenameCharacters(in raw: String) -> String {
        var unsafe = CharacterSet(charactersIn: "/\\:")
        unsafe.formUnion(.controlCharacters)
        unsafe.formUnion(.newlines)
        unsafe.formUnion(.illegalCharacters)

        let replaced = raw.unicodeScalars
            .map { unsafe.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }

        return replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct WebuiScanListing: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        let sessionId: String
        let profile: String?
        let title: String?
        let messageCount: Int?
        let archived: Bool?
        let pinned: Bool?
        let workspace: String?
        let isStreaming: Bool?
        let activeStreamId: String?
        let isCliSession: Bool?
        let sessionSource: String?
        let sourceTag: String?
        let rawSource: String?

        enum CodingKeys: String, CodingKey {
            case sessionId, profile, title, messageCount, archived, pinned, workspace, isStreaming, activeStreamId
            case isCliSession, sessionSource, sourceTag, rawSource
        }

        var isRunning: Bool { isStreaming == true || activeStreamId?.isEmpty == false }

        var isExternal: Bool {
            let sources = [sessionSource, sourceTag, rawSource].map { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
            if sources.contains("webui") { return false }
            return isCliSession == true || sources.contains("external_agent")
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            profile = try? c.decodeIfPresent(String.self, forKey: .profile)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            messageCount = c.decodeLossyIntIfPresent(forKey: .messageCount)
            archived = try? c.decodeIfPresent(Bool.self, forKey: .archived)
            pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
            workspace = try? c.decodeIfPresent(String.self, forKey: .workspace)
            isStreaming = try? c.decodeIfPresent(Bool.self, forKey: .isStreaming)
            activeStreamId = try? c.decodeIfPresent(String.self, forKey: .activeStreamId)
            isCliSession = try? c.decodeIfPresent(Bool.self, forKey: .isCliSession)
            sessionSource = try? c.decodeIfPresent(String.self, forKey: .sessionSource)
            sourceTag = try? c.decodeIfPresent(String.self, forKey: .sourceTag)
            rawSource = try? c.decodeIfPresent(String.self, forKey: .rawSource)
        }
    }

    let sessions: [Row]
    let allProfiles: Bool?
    let activeProfile: String?

    enum CodingKeys: String, CodingKey { case sessions, allProfiles, activeProfile }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decode([Slot].self, forKey: .sessions).compactMap(\.row).filter { !$0.sessionId.isEmpty && !$0.isExternal }
        allProfiles = try? c.decodeIfPresent(Bool.self, forKey: .allProfiles)
        activeProfile = try? c.decodeIfPresent(String.self, forKey: .activeProfile)
    }

    private struct Slot: Decodable {
        let row: Row?
        init(from decoder: Decoder) throws { row = try? Row(from: decoder) }
    }
}

extension APIClient {
    func moveScanSessions() async throws -> WebuiScanListing {
        try await send(endpoint: .moveScanSessions, method: "GET")
    }

    static func moveCopyClient(
        baseURL: URL,
        headers: [CustomHeader],
        cookies: [HTTPCookie],
        configuration: URLSessionConfiguration = .ephemeral
    ) -> (client: APIClient, session: URLSession) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage
        cookies.forEach { jar?.setCookie($0) }
        configuration.httpCookieStorage = jar
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        let session = URLSession(configuration: configuration)
        return (APIClient(baseURL: baseURL, session: session, customHeaderProvider: { headers }), session)
    }
}
