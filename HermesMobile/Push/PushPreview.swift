import CryptoKit
import Foundation
import Security
import UserNotifications

// Shared by the app and `HermesNotificationService`. Everything here is Foundation,
// CryptoKit and Security only: the extension links no networking, no SwiftData and
// no third-party package, so nothing in this file may reach for one.

/// The part of a relay banner the phone reads outside `aps`. Every field is
/// optional: the relay and plugin ship on their own schedule, and a payload this
/// build cannot read stays the content-free notification it arrived as.
struct PushPayload: Equatable {
    /// `sha256(install_key)`, lowercase hex: names the pairing, and so the server.
    var installHash: String?
    var sessionID: String?
    /// The plugin's coarse source: `bot`, `webui` or `other`.
    var source: String?
    var kind: String?
    /// Base64 of `nonce(12) || ciphertext || tag(16)`. Nil when the host could not
    /// encrypt, the user turned previews off, or the blob would not fit in a push.
    var sealed: String?
    /// The bot's Profile, written back by the extension once a preview opens. It
    /// only exists inside the ciphertext, and a tap needs it to pick the bot.
    var profile: String?

    static let profileKey = "hermex_profile"

    init(userInfo: [AnyHashable: Any]) {
        installHash = userInfo["install_hash"] as? String
        sessionID = userInfo["session_id"] as? String
        source = userInfo["source"] as? String
        kind = userInfo["kind"] as? String
        sealed = userInfo["sealed"] as? String
        profile = userInfo[Self.profileKey] as? String
    }
}

/// The plaintext the plugin sealed on the user's host.
struct PushPreview: Decodable, Equatable {
    var title: String?
    var subtitle: String?
    var body: String?
    var profile: String?
    var requestID: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, body, profile
        case requestID = "request_id"
    }

    /// Opens a sealed preview (AES-256-GCM, AAD `hermex-preview-v1:<sha256 hex of
    /// install_key>`). Nil for any failure — a wrong key, a tampered or truncated
    /// blob, plaintext that is not the expected JSON — so callers have exactly one
    /// fallback: leave the notification as delivered.
    static func open(sealed: String, keys: PushPreviewKeys) -> PushPreview? {
        guard let blob = Data(base64Encoded: sealed),
              let rawKey = Data(base64Encoded: keys.previewKey), rawKey.count == 32,
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(
                  box, using: SymmetricKey(data: rawKey),
                  authenticating: Data("hermex-preview-v1:\(keys.installHash)".utf8))
        else { return nil }
        return try? JSONDecoder().decode(PushPreview.self, from: plaintext)
    }
}

/// The two halves of a stored `PushPairing` the extension needs. It decodes the
/// same Keychain JSON the app writes, and nothing else from it.
struct PushPreviewKeys: Decodable, Equatable {
    let installKey: String
    let previewKey: String

    var installHash: String {
        SHA256.hash(data: Data(installKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The pairing a payload names. One phone can be paired with several servers,
    /// and a preview must only ever be opened with its own server's key.
    static func matching(installHash: String?, in candidates: [PushPreviewKeys]) -> PushPreviewKeys? {
        guard let installHash, !installHash.isEmpty else { return nil }
        return candidates.first { $0.installHash == installHash }
    }

    /// Every pairing in the shared push access group, read with Security directly
    /// so the extension does not link KeychainAccess. The items are the generic
    /// passwords `KeychainPushPairingStore` writes; anything unreadable is skipped.
    static func stored(bundle: Bundle = .main) -> [PushPreviewKeys] {
        guard let service = bundle.object(forInfoDictionaryKey: "HermesKeychainService") as? String,
              let accessGroup = bundle.object(forInfoDictionaryKey: "HermesKeychainAccessGroup") as? String,
              !service.isEmpty, !accessGroup.isEmpty else { return [] }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true,
            kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(PushPreviewKeys.self, from: data)
        }
    }
}

extension PushPreview {
    /// The extension's whole job, kept here so it is testable without an extension
    /// process. A preview that opens replaces the banner text and leaves its Profile
    /// behind for the tap. Anything else — previews off, no pairing for this install,
    /// a wrong key, a tampered blob — keeps the banner content-free and only puts the
    /// relay's English placeholder into the phone's language.
    static func rewrite(_ content: UNMutableNotificationContent, candidates: [PushPreviewKeys]) {
        let payload = PushPayload(userInfo: content.userInfo)
        guard let sealed = payload.sealed,
              let keys = PushPreviewKeys.matching(installHash: payload.installHash, in: candidates),
              let preview = open(sealed: sealed, keys: keys)
        else {
            content.body = String(localized: "New activity")
            return
        }
        if let title = preview.title, !title.isEmpty { content.title = title }
        if let subtitle = preview.subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let body = preview.body, !body.isEmpty { content.body = body }
        if let profile = preview.profile, !profile.isEmpty {
            content.userInfo[PushPayload.profileKey] = profile
        }
    }
}
