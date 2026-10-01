import Foundation

/// The hermes-agent releases Hermex signs in to. `HermesConnection` refuses a host older
/// than `minimumVersion` before any password goes out; anything newer, or tested or not,
/// connects without a warning (#626).
enum HermesCompatibility {
    /// The oldest release that publishes the gateway contract Hermex is built on.
    static let minimumVersion = "0.21.3"
    /// The release Hermex was validated against. Mirrors line 2 of
    /// `HERMES_AGENT_TESTED_SHA`; `BotConnectionVersionTests` fails when they drift.
    static let testedVersion = "0.21.5"

    /// Whether a host reporting `version` may sign in. A missing or unreadable version
    /// counts as supported: the pin always reports one, so its absence means a proxy or
    /// a fork, not an old host.
    static func isSupported(_ version: String?) -> Bool {
        guard let reported = release(version), let minimum = release(minimumVersion) else { return true }
        return !reported.lexicographicallyPrecedes(minimum)
    }

    /// The leading `MAJOR.MINOR.PATCH` of `version` as numbers, so a canary
    /// (`0.21.4+canary…`) reads as its base release. Nil when missing, partial or unreadable.
    static func release(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let numbers = version.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }.split(separator: ".").compactMap { Int($0) }
        return numbers.count >= 3 ? Array(numbers.prefix(3)) : nil
    }
}
