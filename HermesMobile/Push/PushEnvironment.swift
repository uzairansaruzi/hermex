import Foundation

enum PushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production

    init?(entitlementValue: String) {
        switch entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "development": self = .sandbox
        case "production": self = .production
        default: return nil
        }
    }

    static func current(bundle: Bundle = .main) -> PushEnvironment? {
        guard let raw = bundle.object(forInfoDictionaryKey: "HermesAPSEnvironment") as? String else { return nil }
        return PushEnvironment(entitlementValue: raw)
    }
}

enum PushBundleIdentifier {
    static let supported: Set<String> = [
        "com.uzairansar.hermesmobile",
        "com.uzairansar.hermesmobile.branch"
    ]

    static func current(bundle: Bundle = .main) -> String? {
        guard let identifier = bundle.bundleIdentifier, supported.contains(identifier) else { return nil }
        return identifier
    }
}

struct PushBuildIdentity: Equatable, Sendable {
    let bundleID: String
    let environment: PushEnvironment

    init?(bundle: Bundle = .main) {
        guard let bundleID = PushBundleIdentifier.current(bundle: bundle),
              let environment = PushEnvironment.current(bundle: bundle) else { return nil }
        self.bundleID = bundleID
        self.environment = environment
    }

    init(bundleID: String, environment: PushEnvironment) {
        self.bundleID = bundleID
        self.environment = environment
    }
}
