import SwiftUI
import UserNotifications

enum NotificationOffer {
    enum Offer: Equatable {
        case localAlerts
        case push
    }

    static let hasOfferedKey = "notificationOffer.hasOffered"

    static func decide(
        hasOffered: Bool,
        localAlertsEnabled: Bool,
        authorization: UNAuthorizationStatus,
        isPaired: @autoclosure () -> Bool,
        canPair: @autoclosure () -> Bool
    ) -> Offer? {
        guard !hasOffered, !localAlertsEnabled, authorization != .denied, !isPaired() else { return nil }
        return canPair() ? .push : .localAlerts
    }

    @MainActor
    static func claim(
        server: URL,
        defaults: UserDefaults = .standard,
        isCurrent: @MainActor () -> Bool = { true },
        isPushPaired: @MainActor (URL) -> Bool = { @MainActor in PushRegistrar.shared?.pairing(for: $0) != nil },
        canPair: @MainActor (URL) -> Bool = { @MainActor in
            PushRegistrar.shared != nil && (try? BotConnectionStore().load(server: $0)) != nil
        },
        scheduler: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler()
    ) async -> Offer? {
        guard !defaults.bool(forKey: hasOfferedKey),
              !defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey) else { return nil }
        let authorization = await scheduler.authorizationStatus()
        guard isCurrent(),
              let offer = decide(
                hasOffered: defaults.bool(forKey: hasOfferedKey),
                localAlertsEnabled: defaults.bool(forKey: ResponseCompletionNotifications.isEnabledKey),
                authorization: authorization,
                isPaired: isPushPaired(server),
                canPair: canPair(server)
              ) else { return nil }
        defaults.set(true, forKey: hasOfferedKey)
        return offer
    }
}

extension View {
    func notificationOfferAlert(_ offer: Binding<NotificationOffer.Offer?>) -> some View {
        modifier(NotificationOfferAlertModifier(offer: offer))
    }

    func openNotificationSettings(perform handler: @escaping () -> Void) -> some View {
        modifier(OpenNotificationSettingsModifier(handler: handler))
    }
}

private struct NotificationOfferAlertModifier: ViewModifier {
    @Binding var offer: NotificationOffer.Offer?
    @Environment(\.openNotificationSettings) private var openNotificationSettings

    func body(content: Content) -> some View {
        content.alert(
            "Want a notification when it’s done?",
            isPresented: Binding(
                get: { offer != nil },
                set: { if !$0 { offer = nil } }
            ),
            presenting: offer
        ) { offer in
            Button("Not now", role: .cancel) {}
            switch offer {
            case .localAlerts:
                Button("Notify Me") {
                    Task { _ = await ResponseCompletionNotificationService.enable() }
                }
                .keyboardShortcut(.defaultAction)
            case .push:
                Button("Open Settings") { openNotificationSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        } message: { offer in
            switch offer {
            case .localAlerts:
                Text("Hermex can alert you when a reply finishes or fails while the app is in the background. You can change this in Settings → Notifications.")
            case .push:
                Text("Push notifications reach this iPhone even when Hermex is closed. Setup can change your Hermes host, so it runs step by step in Settings.")
            }
        }
    }
}

final class OpenNotificationSettingsAction {
    var handler: () -> Void = {}

    func callAsFunction() { handler() }
}

private struct OpenNotificationSettingsKey: EnvironmentKey {
    static let defaultValue = OpenNotificationSettingsAction()
}

extension EnvironmentValues {
    var openNotificationSettings: OpenNotificationSettingsAction {
        get { self[OpenNotificationSettingsKey.self] }
        set { self[OpenNotificationSettingsKey.self] = newValue }
    }
}

private struct OpenNotificationSettingsModifier: ViewModifier {
    let handler: () -> Void
    @State private var action = OpenNotificationSettingsAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content.environment(\.openNotificationSettings, action)
    }
}
