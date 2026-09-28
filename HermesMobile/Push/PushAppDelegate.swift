import UIKit
import UserNotifications

/// SwiftUI has no scene-level hook for APNs device tokens or notification taps, so
/// this delegate hands tokens to `PushRegistrar` and taps to
/// `PushNotificationRouter`. Nothing else belongs here.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes, or the tap that cold-started the app is lost.
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { PushRegistrar.shared?.refreshOnLaunch() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared?.didRegisterForRemoteNotifications(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared?.didFailToRegisterForRemoteNotifications(error: error) }
    }

    /// A relay push that arrives while the app is open shows as a banner, except the
    /// open conversation's quiet kinds (`PushPresence`).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            completionHandler(PushPresence.presentation(
                userInfo: userInfo, viewer: PushPresence.shared.viewer, pairings: Self.configuredPairings() ?? [:]))
        }
    }

    /// A tapped banner queues the conversation deep link on `AppIntentRouter`, which
    /// `ContentView` drains on cold and warm launch alike.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        // The system does not promise a thread here, so hop rather than assume.
        Task { @MainActor in
            let activeServer = ServerRegistry.shared.activeServerID.flatMap(URL.init(string:))
            if let pairings = Self.configuredPairings() {
                if let destination = PushNotificationRouter.webuiDestination(
                    userInfo: userInfo, pairings: pairings, activeServer: activeServer) {
                    AppIntentRouter.shared.requestDeepLink(destination.url)
                } else if let destination = PushNotificationRouter.botDestination(
                    userInfo: userInfo, pairings: pairings, activeServer: activeServer) {
                    AppIntentRouter.shared.requestDeepLink(HermesDeepLink.botURL(for: destination))
                }
            }
            completionHandler()
        }
    }

    /// Stored pairings for servers still configured; nil when the Keychain can't be read.
    @MainActor private static func configuredPairings() -> [URL: PushPairing]? {
        guard let stored = try? KeychainPushPairingStore()?.allPairings() else { return nil }
        let configured = Set(ServerRegistry.shared.servers.map(\.id))
        return stored.filter { configured.contains($0.key.absoluteString) }
    }
}
