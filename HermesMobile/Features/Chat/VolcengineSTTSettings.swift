import Foundation

/// Storage keys and defaults for Volcengine streaming STT configuration.
enum VolcengineSTTSettings {
    static let apiKeyKey = "volcengineSTTApiKey"
    static let resourceIdKey = "volcengineSTTResourceId"
    static let defaultResourceId = "volc.seedasr.sauc.duration"

    /// Whether volcengine streaming is configured (API key is present).
    static var isConfigured: Bool {
        guard let key = UserDefaults.standard.string(forKey: apiKeyKey) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build a configuration from stored settings + optional hot words.
    static func configuration(hotwords: [String] = []) -> VolcengineStreamingSTT.Configuration? {
        guard let apiKey = UserDefaults.standard.string(forKey: apiKeyKey),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let resourceId = UserDefaults.standard.string(forKey: resourceIdKey)?.nilIfEmpty
            ?? defaultResourceId

        return VolcengineStreamingSTT.Configuration(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            resourceId: resourceId,
            hotwords: hotwords
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
