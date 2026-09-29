import SwiftUI
import UserNotifications

/// The one-time question after the first run started from the phone (#863): "Want a
/// notification when it’s done?" Asked once per install, never per server. #769's
/// offer after the first Hermes connection checks and sets the same flag, so whichever
/// surface asks first silences the other.
enum NotificationOffer {
    enum Offer: Equatable {
        /// Turns on Response Complete Alerts, asking iOS for permission if Hermex never has.
        case localAlerts
        /// Opens Settings → Notifications, where push setup runs behind its own confirmation.
        case push
    }

    /// Standard `UserDefaults`, per install: a bool is not credential-like.
    static let hasOfferedKey = "notificationOffer.hasOffered"

    /// What to offer, or nil when there is nothing worth asking: already asked, local
    /// alerts already on, iOS permission refused, or the active server already paired.
    /// `canPair` means this build can push and the active server has a saved Hermes
    /// connection to set it up with. Both are Keychain reads, so they are evaluated only
    /// when they can still change the answer: never on a denied install, and `canPair`
    /// never on a paired server.
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

    /// The offer for a run that just started on `server`, marked as made before it is
    /// returned, so a crash or kill can never show it twice. Nil leaves the flag unset,
    /// so a later run can still ask. `isCurrent` is read after the permission check: a
    /// chat that closed meanwhile shows nothing, so it must not use the offer up.
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
        // Every send after the offer, or with alerts on, ends here before any permission
        // or Keychain read. Denied and paired installs still check permission each send.
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
    /// Presents a claimed offer as one system alert. Only the offer's own button acts;
    /// "Not now" changes no setting and no permission.
    func notificationOfferAlert(_ offer: Binding<NotificationOffer.Offer?>) -> some View {
        modifier(NotificationOfferAlertModifier(offer: offer))
    }

    /// Publishes `handler` as every descendant chat's way to Settings → Notifications,
    /// without invalidating those chats when the caller rebuilds the closure.
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

/// Opens Settings at Notifications with the push section expanded. `SessionListView`
/// installs it, so every chat it hosts inherits it: opened from the list, a new chat,
/// a fork, or Archived Sessions. A reference, like `ChatDisclosureToggleAction`: a
/// closure rebuilt on every list pass would invalidate every chat reading it.
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

// The stable instance lives in the modifier's own state, not the caller's, so the
// handler capturing the caller cannot form a cycle that outlives the screen.
private struct OpenNotificationSettingsModifier: ViewModifier {
    let handler: () -> Void
    @State private var action = OpenNotificationSettingsAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content.environment(\.openNotificationSettings, action)
    }
}
