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
