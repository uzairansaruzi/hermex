import Foundation

public enum SourceTextCategory: String, Hashable, Codable, Sendable { case chat, command, question, answer, path, backendError }
public enum RedactionContext: String, Hashable, Codable, Sendable { case route, widget, diagnostics, receipt, log }

public enum WatchRedactor {
    public static func fixedPlaceholder(for category: SourceTextCategory) -> String {
        switch category {
        case .chat: return "Private chat content"
        case .command: return "Private command"
        case .question: return "Private question"
        case .answer: return "Private answer"
        case .path: return "Private path"
        case .backendError: return "Private server error"
        }
    }

    public static func displayName(aliasIndex: Int) throws -> RedactedDisplayName {
        guard aliasIndex >= 0, aliasIndex < Int.max else { throw DTOValidationError.invalidCount }
        return try RedactedDisplayName("Server\(aliasIndex + 1)")
    }

    public static func validateNonSecretProjection(_ data: Data, context: RedactionContext) throws {
        let limit: Int
        switch context {
        case .route: limit = ContractLimits.routeJSONBytes
        case .widget: limit = ContractLimits.widgetJSONBytes
        case .diagnostics, .receipt, .log: limit = 16_384
        }
        guard data.count <= limit, let string = String(data: data, encoding: .utf8) else {
            throw DTOValidationError.tooLarge
        }

        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            try validateJSON(json)
        } else {
            try validateString(string)
        }
    }

    private static let forbiddenKeys: Set<String> = [
        "authorization", "cookie", "setcookie", "password", "secret", "token", "apikey",
        "host", "origin", "uri", "url", "command", "prompt", "response", "rawerror", "rawpath", "filename"
    ]

    private static let forbiddenHeaders: Set<String> = [
        "host", "cookie", "setcookie", "contentlength", "connection", "keepalive",
        "proxyauthenticate", "proxyauthorization", "te", "trailer", "transferencoding", "upgrade"
    ]

    private static func validateJSON(_ value: Any) throws {
        if let string = value as? String {
            try validateString(string)
        } else if let array = value as? [Any] {
            for item in array { try validateJSON(item) }
        } else if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalized = normalize(key)
                guard !forbiddenKeys.contains(normalized), !forbiddenHeaders.contains(normalized) else {
                    throw DTOValidationError.tooLarge
                }
                try validateJSON(child)
            }
        }
    }

    private static func validateString(_ string: String) throws {
        guard !string.unicodeScalars.contains(where: {
            $0.value < 32 || $0.value == 127 || $0.value == 0x2028 || $0.value == 0x2029
        }) else { throw DTOValidationError.tooLarge }

        let lower = string.lowercased()
        guard !lower.contains("u01c_secret_canary"),
              !lower.contains("http://"), !lower.contains("https://"), !lower.contains("://"),
              !lower.contains("bearer "), !lower.contains("basic "),
              !lower.contains("authorization:"), !lower.contains("cookie:"), !lower.contains("set-cookie:"),
              !lower.contains("api_key="), !lower.contains("api-key="), !lower.contains("token="),
              !lower.contains("password="), !lower.contains("prompt="), !lower.contains("response="),
              !lower.contains("command="), !lower.contains("raw_error="), !lower.contains("rawerror="),
              !lower.hasPrefix("/"), !lower.hasPrefix("~/"), !lower.contains("/users/"),
              !lower.contains("/home/"), !lower.contains("\\users\\"), !isWindowsAbsolutePath(lower)
        else { throw DTOValidationError.tooLarge }
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isWindowsAbsolutePath(_ value: String) -> Bool {
        guard value.utf8.count >= 3 else { return false }
        let characters = Array(value)
        return characters[0].isLetter && characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/")
    }
}
