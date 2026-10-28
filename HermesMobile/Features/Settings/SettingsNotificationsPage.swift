import SwiftUI
import UserNotifications

/// Notifications (#1252): the active server's push setup, then the alerts that apply on this
/// iPhone to every server.
struct SettingsNotificationsPage: View {
    let server: URL

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) private var showsLiveActivityResponseExcerpts = false
    @State private var notificationPermissionStatus: UNAuthorizationStatus?
    @State private var notificationStatusMessage: String?

    var body: some View {
        HermexPushSettingsPage(server: server) {
            Section {
                Toggle(isOn: responseCompletionNotificationBinding) {
                    SettingsLabel(
                        title: String(localized: "Response Complete Alerts"),
                        systemImage: "bell",
                        note: String(localized: "For servers without push.")
                    )
                }

                #if !targetEnvironment(macCatalyst)
                Toggle(isOn: $showsLiveActivityResponseExcerpts) {
                    SettingsLabel(
                        title: String(localized: "Live Activity Excerpts"),
                        systemImage: "lock",
                        note: String(localized: "Reply text on the Lock Screen and Dynamic Island.")
                    )
                }
                #endif
            } header: {
                #if !targetEnvironment(macCatalyst)
                Text("On this iPhone · All servers")
                #endif
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let notificationStatusText {
                        Text(notificationStatusText)
                    }
                    // A denied permission must be restored in the platform's system settings.
                    #if targetEnvironment(macCatalyst)
                    if notificationPermissionStatus == .denied, let settingsURL = macNotificationSettingsURL {
                        Link("Open Settings", destination: settingsURL)
                    }
                    #else
                    if notificationPermissionStatus == .denied,
                       let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Link("Open Settings", destination: settingsURL)
                    }
                    #endif
                }
            }
        }
        // Re-read on return from iPhone Settings so the footer and link drop a stale denial.
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshNotificationPermissionStatus() }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Opens this build's notification pane; app-settings:notifications is an iOS route.
    private var macNotificationSettingsURL: URL? {
        var components = URLComponents(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let identifier = Bundle.main.bundleIdentifier {
            components?.queryItems = [URLQueryItem(name: "id", value: identifier)]
        }
        return components?.url
    }
    #endif

    private var notificationStatusText: String? {
        #if targetEnvironment(macCatalyst)
        switch notificationPermissionStatus {
        case .authorized?, .provisional?, .ephemeral?:
            return nil
        case .notDetermined?:
            return String(localized: "Permission not requested.")
        case .denied?:
            return String(localized: "Notifications are off for Hermex")
        case nil:
            return notificationStatusMessage
        default:
            return String(localized: "Notifications unavailable.")
        }
        #else
        notificationStatusMessage ?? notificationPermissionStatus.map(ResponseCompletionNotificationService.permissionLabel)
        #endif
    }

    private var responseCompletionNotificationBinding: Binding<Bool> {
        Binding(
            get: { isResponseCompletionNotificationsEnabled },
            set: { isEnabled in
                if isEnabled {
                    Task {
                        await enableResponseCompletionNotifications()
                    }
                } else {
                    isResponseCompletionNotificationsEnabled = false
                    Task {
                        await refreshNotificationPermissionStatus()
                    }
                }
            }
        )
    }

    private func refreshNotificationPermissionStatus() async {
        let status = await ResponseCompletionNotificationService.authorizationStatus()
        notificationPermissionStatus = status

        if !status.allowsSettingsToggleOn {
            isResponseCompletionNotificationsEnabled = false
        }

        notificationStatusMessage = nil
    }

    /// Shared with the chat's one-time offer, which turns the same preference on.
    private func enableResponseCompletionNotifications() async {
        let result = await ResponseCompletionNotificationService.enable()
        notificationPermissionStatus = result.authorizationStatus
        notificationStatusMessage = result.message
    }
}

private extension UNAuthorizationStatus {
    var allowsSettingsToggleOn: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
