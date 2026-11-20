import CryptoKit
import Foundation
import Security
import UserNotifications

struct PushPayload: Equatable {
    var installHash: String?
    var sessionID: String?
    var source: String?
    var kind: String?
    var sealed: String?
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

struct PushPreview: Codable, Equatable {
    var title: String?
    var subtitle: String?
    var body: String?
    var profile: String?
    var requestID: String?
    var botName: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, body, profile
        case requestID = "request_id"
        case botName = "bot_name"
    }

    static func open(sealed: String, keys: PushPreviewKeys) -> PushPreview? {
        guard let blob = Data(base64Encoded: sealed),
              let rawKey = Data(base64Encoded: keys.previewKey), rawKey.count == 32,
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(
                  box, using: SymmetricKey(data: rawKey), authenticating: keys.previewAAD)
        else { return nil }
        return try? JSONDecoder().decode(PushPreview.self, from: plaintext)
    }
}

struct PushPreviewKeys: Decodable, Equatable {
    let installKey: String
    let previewKey: String

    var installHash: String {
        SHA256.hash(data: Data(installKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var previewAAD: Data { Data("hermex-preview-v1:\(installHash)".utf8) }

    static func matching(installHash: String?, in candidates: [PushPreviewKeys]) -> PushPreviewKeys? {
        guard let installHash, !installHash.isEmpty else { return nil }
        return candidates.first { $0.installHash == installHash }
    }

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
    static func rewrite(_ content: UNMutableNotificationContent, candidates: [PushPreviewKeys]) {
        let payload = PushPayload(userInfo: content.userInfo)
        guard let sealed = payload.sealed,
              let keys = PushPreviewKeys.matching(installHash: payload.installHash, in: candidates),
              let preview = open(sealed: sealed, keys: keys)
        else {
            content.body = String(localized: "New activity")
            return
        }
        if let title = preview.localizedTitle(kind: payload.kind) ?? preview.title, !title.isEmpty {
            content.title = title
        }
        if let subtitle = preview.subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let body = preview.body, !body.isEmpty { content.body = body }
        if let profile = preview.profile, !profile.isEmpty {
            content.userInfo[PushPayload.profileKey] = profile
        }
    }

    func localizedTitle(kind: String?) -> String? {
        guard let name = botName, !name.isEmpty else { return nil }
        switch kind {
        case "approval":
            return String(localized: "\(name) · Approval needed", comment: "Push banner title; %@ is the bot's name.")
        case "clarify":
            return String(localized: "\(name) · Question", comment: "Push banner title; %@ is the bot's name.")
        case "turn_error":
            return String(localized: "\(name) · Turn failed", comment: "Push banner title; %@ is the bot's name.")
        case "reply":
            return name
        default:
            return nil
        }
    }
}
