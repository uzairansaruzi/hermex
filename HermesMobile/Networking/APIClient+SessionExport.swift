import Foundation

/// Formats accepted by `GET /api/session/export?format=…`. The server defaults
/// to JSON when the param is absent, but the app always sends it explicitly.
/// HTML is the self-contained human-readable transcript (best for sharing);
/// JSON is the machine-readable session dump (pairs with a future import).
enum SessionExportFormat: String, CaseIterable {
    case html
    case json

    var fileExtension: String { rawValue }
}

/// A downloaded session export: the raw file bytes plus the filename the share
/// sheet should offer (never "download.bin").
struct SessionExportFile: Equatable {
    let data: Data
    let filename: String
}

extension APIClient {
    /// Downloads a session transcript via `GET /api/session/export`
    /// (`session_id` + `format` query params). The response is a file download
    /// (`text/html` or `application/json`), not a JSON envelope, so this
    /// bypasses the decoding `send()` helper like transcribe/TTS do.
    ///
    /// The filename comes from the server's `Content-Disposition` header
    /// (upstream sends `attachment; filename="hermes-<sid>.<ext>"`); if that
    /// header is missing or unparsable, it falls back to a sanitized
    /// `<title-or-id>.<ext>`. Errors reuse `sendData`'s mapping: 401 →
    /// `.unauthorized`, other non-2xx (400 missing param, 404 unknown/foreign-
    /// profile session) → `.http` carrying the server's error body.
    func exportSession(
        id: String,
        format: SessionExportFormat,
        fallbackTitle: String? = nil
    ) async throws -> SessionExportFile {
        let (data, response) = try await sendDataReturningResponse(
            endpoint: .exportSession(sessionID: id, format: format),
            method: "GET",
            encodedBody: nil,
            // The 2xx response is a file download (text/html or
            // application/json), so don't claim we only accept JSON.
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
    /// Derives the filename to offer in the share sheet.
    ///
    /// Preference order:
    /// 1. `filename="…"` (or unquoted `filename=…`) from `Content-Disposition`.
    /// 2. Sanitized session title + the format's extension.
    /// 3. `hermes-<session-id>.<ext>` (mirrors the upstream server's own name).
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

    /// Extracts the `filename` parameter value from a `Content-Disposition`
    /// header (quoted or bare token). Intentionally does not implement the
    /// RFC 5987 `filename*=` extended form — upstream never sends it, and the
    /// sanitized fallback covers any server that does.
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

    /// Keeps only the last path component and strips characters that are
    /// unsafe in filenames, so a hostile/buggy header can't escape the temp
    /// directory or produce an unusable name.
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

    /// Sanitizes free text (session title / ID) into a filename stem, or nil
    /// when nothing usable remains.
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

        // Collapse whitespace runs and trim so titles like "  a  /  b  " come
        // out as "a b" rather than "a    b".
        return replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Move to Hermes's scan listing (#1213), `GET /api/sessions?all_profiles=1&include_archived=1`:
/// every webui chat with the Profile holding it. When `allProfiles` isn't true the server listed
/// only `activeProfile` (its isolated-Profile mode), so other Profiles went unscanned, not empty.
/// A row that can't be read, or has no id, is skipped; a reply without `sessions` is a failed read.
struct WebuiScanListing: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        let sessionId: String
        /// Nil for a legacy row of the webui's root Profile.
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

        /// The webui is streaming a reply into it now, so a Move must wait (#1218). Either field
        /// counts, as in the session list (`SessionRowView.isActiveStreaming`).
        var isRunning: Bool { isStreaming == true || activeStreamId?.isEmpty == false }

        /// A Hermes CLI/TUI session or an external agent's transcript (Claude Code) the webui only
        /// shows, not a webui chat, so a Move never counts, waits for or copies it (#1218). The
        /// webui sets `is_cli_session` from its own classifier, which keeps webui, cron, webhook
        /// and messaging rows out; Claude Code rows also carry `session_source: external_agent`.
        /// A webui source marker wins over a stale CLI flag, as in the webui and the session list.
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

    /// The webui's own chats; external rows are dropped here, so no Move reader sees them.
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
    /// Every webui chat across Profiles for Move to Hermes's scan (#1213). Read-only: it never
    /// switches the Profile this client's cookie names.
    func moveScanSessions() async throws -> WebuiScanListing {
        try await send(endpoint: .moveScanSessions, method: "GET")
    }

    /// A client for one Move's copy from the webui at `baseURL` (#1213), sending `headers` (that
    /// server's own, not the active server's) from a cookie jar of its own seeded with `cookies`,
    /// its sign-in. The Profile cookie each `switchProfile` sets lands only in that jar, so the
    /// app's screens never see it and none of them can change it mid-copy. `configuration` is
    /// only for tests' protocol classes; its cookie storage is always replaced. Invalidate the
    /// returned session once the copy ends.
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
