import SwiftUI
import UserNotifications

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

                Toggle(isOn: $showsLiveActivityResponseExcerpts) {
                    SettingsLabel(
                        title: String(localized: "Live Activity Excerpts"),
                        systemImage: "lock",
                        note: String(localized: "Reply text on the Lock Screen and Dynamic Island.")
                    )
                }
            } header: {
                Text("On this iPhone · All servers")
            } appFooter: {
                VStack(alignment: .leading, spacing: 4) {
                    if let notificationStatusText {
                        Text(notificationStatusText)
                    }
                    if notificationPermissionStatus == .denied,
                       let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Link("Open Settings", destination: settingsURL)
                    }
                }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshNotificationPermissionStatus() }
        }
    }

    private var notificationStatusText: String? {
        notificationStatusMessage ?? notificationPermissionStatus.map(ResponseCompletionNotificationService.permissionLabel)
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
