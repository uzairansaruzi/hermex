import Foundation

/// Which APNs environment this build's device tokens belong to.
///
/// The relay must be told the truth: Apple rejects a token registered under the
/// wrong environment and the relay then revokes the device, which looks like
/// "push silently stopped working". The value is *not* derived from the bundle
/// suffix — Branch TestFlight is a production build — but from `APS_ENVIRONMENT`,
/// the one build setting that writes both the `aps-environment` entitlement
/// (`HermesMobile.entitlements`) and the `HermesAPSEnvironment` key read below
/// (`Info.plist`). It is a project-level build setting in `HermesMobile.xcodeproj`:
/// `development` for Debug, `production` for Release, so at build time the two
/// always agree. Only export re-signing could make them differ, and nothing
/// checks the uploaded app: both upload paths archive Release
/// (`release-candidate-testflight.yml`, `scripts/branch-testflight`) and export
/// straight to App Store Connect.
enum PushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production

    /// Maps the entitlement's vocabulary onto the relay's. Returns nil for an
    /// unrecognized value so the caller skips registration instead of guessing:
    /// a wrong guess costs the user their notifications.
    init?(entitlementValue: String) {
        switch entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "development": self = .sandbox
        case "production": self = .production
        default: return nil
        }
    }

    /// Reads `HermesAPSEnvironment`, the Info.plist mirror of `APS_ENVIRONMENT`.
    static func current(bundle: Bundle = .main) -> PushEnvironment? {
        guard let raw = bundle.object(forInfoDictionaryKey: "HermesAPSEnvironment") as? String else { return nil }
        return PushEnvironment(entitlementValue: raw)
    }
}

/// The two bundle identifiers the relay accepts. Anything else means this build
/// was renamed for a fork and cannot use the maintainer's relay.
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

/// Everything about *this build* the relay needs in a device registration.
/// Nil when the build cannot register at all, so `PushRegistrar` can stop early
/// rather than send a body the relay would reject with a 400.
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
