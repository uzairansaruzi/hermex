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

    /// A tapped banner queues the conversation deep link on `AppIntentRouter`, which
    /// `ContentView` drains on cold and warm launch alike. Foreground presentation
    /// is deliberately not implemented, so it stays the system default.
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
            if let stored = try? KeychainPushPairingStore()?.allPairings() {
                let configured = Set(ServerRegistry.shared.servers.map(\.id))
                let pairings = stored.filter { configured.contains($0.key.absoluteString) }
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
}
