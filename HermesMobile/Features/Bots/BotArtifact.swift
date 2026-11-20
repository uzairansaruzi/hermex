import Foundation

struct BotArtifactContext: Hashable {
    let connectionID: UUID
    let profile: String
    let sessionID: String
    let generation: Int
}

enum BotArtifactFailure: Error, LocalizedError {
    case unavailable, tooLarge, invalidReference, folder

    var errorDescription: String? {
        switch self {
        case .unavailable, .folder: return String(localized: "This file could not be opened. It may be missing or unavailable on this Hermes connection.")
        case .tooLarge: return String(localized: "This file is too large to preview on this device (25 MB maximum).")
        case .invalidReference: return String(localized: "This reference does not name a file on this Bot connection.")
        }
    }
}

enum BotArtifactReference {
    static func path(_ raw: String, address: URL) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), !value.hasPrefix("//") else {
            throw BotArtifactFailure.invalidReference
        }
        if BotAttachmentUpload.isHostAbsolute(value) { return value }
        if let url = URL(string: value), let scheme = url.scheme {
            if scheme.lowercased() == "file", url.host == nil || url.host == "" || url.host == "localhost" {
                return url.path(percentEncoded: false)
            }
            if ["https", "http"].contains(scheme.lowercased()),
               url.scheme == address.scheme, url.host == address.host, url.port == address.port,
               ["/api/fs/download", "/api/files/download", "/api/media", "/api/fs/read-data-url"].contains(url.path),
               let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = parts.queryItems?.first(where: { $0.name == "path" })?.value,
               !path.isEmpty, !path.contains("\0") { return path }
            throw BotArtifactFailure.invalidReference
        }
        return value
    }
}
