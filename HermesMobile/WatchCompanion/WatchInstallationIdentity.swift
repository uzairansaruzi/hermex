import Foundation
import WatchShared

enum WatchInstallationIdentity {
    static let defaultsKey = "watch.installationEpoch"

    static func epoch(defaults: UserDefaults = .standard) -> InstallationEpoch {
        if let raw = defaults.string(forKey: defaultsKey), let uuid = UUID(uuidString: raw) {
            return InstallationEpoch(rawValue: uuid)
        }
        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: defaultsKey)
        return InstallationEpoch(rawValue: uuid)
    }
}
