import CryptoKit
import Foundation

public extension ServerID {
    /// Stable per-URL identity so a watch scope survives process restarts without
    /// storing the server URL on the watch.
    static func derived(from urlString: String) -> ServerID {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return ServerID(rawValue: UUID(uuid: uuid))
    }
}

public extension RedactedDisplayName {
    static func sanitized(_ raw: String, fallback: String = "Server") -> RedactedDisplayName {
        let stripped = raw
            .replacingOccurrences(of: "://", with: " ")
            .replacingOccurrences(of: "@", with: " ")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        var cleaned = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.utf8.count > ContractLimits.displayNameUTF8Bytes {
            var limited = ""
            for character in cleaned {
                let next = limited + String(character)
                if next.utf8.count > ContractLimits.displayNameUTF8Bytes { break }
                limited = next
            }
            cleaned = limited
        }
        if let name = try? RedactedDisplayName(cleaned) {
            return name
        }
        return try! RedactedDisplayName(fallback)
    }
}
