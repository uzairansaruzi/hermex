import Foundation

struct TranscribeResponse: Codable {
    let ok: Bool?
    let transcript: String?
    let error: String?
}
