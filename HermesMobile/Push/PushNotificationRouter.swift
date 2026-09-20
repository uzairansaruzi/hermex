import Foundation

/// Turns a tapped relay banner into the bot it is about. A tap only ever navigates:
/// an approval push lands on the conversation, where approving is its own deliberate
/// action.
@MainActor enum PushNotificationRouter {
    /// Nil when the banner does not name a bot this phone can open: a webui or other
    /// source, a preview that never opened (the Profile lives inside it), a pairing
    /// that has since been wiped, or a server with no Bot connection. The app then
    /// simply opens. The pairing picks the server, so a tap can never land on a bot
    /// with the same Profile name under another server.
    ///
    /// The destination carries no conversation: the payload's `session_id` is the
    /// run's live session, not the bot's durable root, and a bot has one chat.
    static func botDestination(
        userInfo: [AnyHashable: Any],
        pairings: [URL: PushPairing],
        botConnectionID: @MainActor (URL) -> UUID? = { @MainActor url in
            (try? BotConnectionStore().load(server: url))?.id
        }
    ) -> BotDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source == "bot",
              let profile = payload.profile, !profile.isEmpty,
              let installHash = payload.installHash,
              let server = pairings.first(where: { _, pairing in
                  PushPreviewKeys(installKey: pairing.installKey, previewKey: pairing.previewKey)
                      .installHash == installHash
              })?.key,
              let connectionID = botConnectionID(server)
        else { return nil }
        return BotDestination(server: server, connectionID: connectionID, profile: profile)
    }
}
