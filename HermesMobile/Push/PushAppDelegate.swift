import MetricKit
import UIKit
import UserNotifications

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let diagnosticsLog = DiagnosticsLog()

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ComposerDictationLease.supportedOrientations(for: window)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MXMetricManager.shared.add(diagnosticsLog)
        MainActor.assumeIsolated { PushRegistrar.shared?.refreshOnLaunch() }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = AppLockSceneDelegate.self
        return configuration
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
        Task { @MainActor in
            let activeServer = ServerRegistry.shared.activeServerID.flatMap(URL.init(string:))
            if let destination = PushNotificationRouter.localAlertLink(userInfo: userInfo,
                                                                       servers: ServerRegistry.shared.servers) {
                AppIntentRouter.shared.requestDeepLink(destination)
            } else if let pairings = Self.configuredPairings(),
                      let link = PushNotificationRouter.link(userInfo: userInfo, pairings: pairings,
                                                             servers: ServerRegistry.shared.servers,
                                                             activeServer: activeServer) {
                AppIntentRouter.shared.requestDeepLink(link)
            }
            completionHandler()
        }
    }

    @MainActor private static func configuredPairings() -> [URL: PushPairing]? {
        guard let stored = try? KeychainPushPairingStore()?.allPairings() else { return nil }
        let configured = Set(ServerRegistry.shared.servers.map(\.id))
        return stored.filter { configured.contains($0.key.absoluteString) }
    }
}
