import CryptoKit
import SwiftUI
import UIKit

/// What one bot's conversation looks like to its Live Activity (#489). A pure value
/// the conversation projects from its own state at each choke point, so the feed
/// diffs snapshots instead of mirroring every mutation site.
struct BotLiveActivitySnapshot: Equatable {
    enum Phase: Equatable {
        /// Pending reconciliation: say nothing rather than guess.
        case unknown
        /// The socket is gone, so whatever the activity shows is no longer current.
        case disconnected
        /// `turn` names the host's turn; a reconnect inside it reuses the activity.
        case working(turn: String, startedAt: Date)
        case finished(AgentRunActivityStatus)
    }

    enum Work: Equatable {
        case starting, thinking, toolDone, waitingForApproval, waitingForAnswer
        case tool(String?)
        /// Sanitized to the excerpt limit, so a long reply stops changing the snapshot.
        case responding(String)
    }

    let destination: BotDestination
    let title: String
    let phase: Phase
    let work: Work
    let chips: [String]
}

extension AgentRunActivityBot {
    /// Nil for a destination that cannot be written as a link: no tap target, no activity.
    init?(_ destination: BotDestination, avatarFile: String? = nil) {
        guard let url = HermesDeepLink.botURL(for: destination) else { return nil }
        self.init(key: "bot:\(destination.connectionID.uuidString):\(destination.profile)",
                  destinationURL: url, avatarFile: avatarFile)
    }
}

/// Drives the one shared `AgentLiveActivityManager` from Bot conversations. Shared
/// across conversations so leaving a chat and coming back reconciles the activity
/// that chat started. Every stale or end call first checks the manager is still
/// driving this bot, so a webui run or another bot that took the activity over is
/// never touched.
@MainActor final class BotLiveActivityFeed {
    static let shared = BotLiveActivityFeed(manager: AgentLiveActivityManager.shared)

    private let manager: any AgentLiveActivityManaging
    private let showsExcerpts: () -> Bool
    private let writeAvatar: @MainActor (BotProfile, BotDestination) -> String?
    private var last: BotLiveActivitySnapshot?
    /// True while the activity may hold reply text, so turning previews off clears it.
    private var sentExcerpt = false

    init(manager: any AgentLiveActivityManaging,
         showsExcerpts: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: AgentRunLiveActivityPrivacy.showsResponseExcerptsKey)
         },
         writeAvatar: @escaping @MainActor (BotProfile, BotDestination) -> String? = BotLiveActivityFeed.writeAvatar) {
        self.manager = manager
        self.showsExcerpts = showsExcerpts
        self.writeAvatar = writeAvatar
    }

    func sync(_ snapshot: BotLiveActivitySnapshot, profile: BotProfile) {
        guard snapshot != last else { return }
        let previous = last?.destination == snapshot.destination ? last : nil
        last = snapshot
        guard let key = AgentRunActivityBot(snapshot.destination)?.key else { return }

        switch snapshot.phase {
        case .unknown:
            return
        case .disconnected:
            if manager.drivenSessionID == key { manager.markStale() }
        case .finished(let status):
            guard manager.drivenSessionID == key else { return }
            manager.end(status: status, activity: Self.finalLine(status), errorSummary: nil)
        case .working(let turn, let startedAt):
            let adopting = previous?.phase != snapshot.phase || manager.drivenSessionID != key
            if adopting {
                let file = writeAvatar(profile, snapshot.destination)
                guard let bot = AgentRunActivityBot(snapshot.destination, avatarFile: file) else { return }
                manager.startBot(bot, title: snapshot.title, turn: turn, startedAt: startedAt)
            }
            if sentExcerpt, !showsExcerpts() {
                manager.update(.clearResponseExcerpt)
                sentExcerpt = false
            }
            if adopting || previous?.work != snapshot.work { send(snapshot.work) }
            manager.update(.workSummary(snapshot.chips))
        }
    }

    private func send(_ work: BotLiveActivitySnapshot.Work) {
        switch work {
        case .starting: break
        case .thinking: manager.update(.reasoning(""))
        case .tool(let name): manager.update(.toolStarted(name: name))
        case .toolDone: manager.update(.toolCompleted)
        case .waitingForApproval: manager.update(.waitingForApproval)
        case .waitingForAnswer: manager.update(.waitingForClarification)
        case .responding(let excerpt):
            // Reply text reaches the Lock Screen only behind the existing setting;
            // without it the status still moves on to "Writing response".
            if showsExcerpts() {
                manager.update(.interimAssistant(excerpt))
                sentExcerpt = true
            } else {
                manager.update(.responding)
            }
        }
    }

    private static func finalLine(_ status: AgentRunActivityStatus) -> String {
        switch status {
        case .failed: String(localized: "Response failed")
        case .cancelled: String(localized: "Response cancelled")
        default: String(localized: "Response complete")
        }
    }

    /// Renders the bot's avatar, photo or drawn face, to one PNG in the app group and
    /// returns its file name. Only one activity exists at a time, so every other
    /// file is dropped first. The name carries the connection, so equal Profile
    /// names on two connections never share an image.
    static func writeAvatar(_ profile: BotProfile, _ destination: BotDestination) -> String? {
        guard let directory = AgentRunActivityAvatarFile.directory else { return nil }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        for stale in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: stale)
        }

        let photo = BotAvatarStore.shared.images(connectionID: destination.connectionID)[profile.id]
        let renderer = ImageRenderer(content: Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                BotAvatarMarkView(name: profile.id, appearance: BotProfileAppearance(profile: profile), size: 40)
            }
        }
        // The activity card is always dark, so the adaptive body color resolves for it.
        .environment(\.colorScheme, .dark))
        renderer.scale = 3
        let digest = SHA256.hash(data: Data(profile.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "\(destination.connectionID.uuidString)-\(digest).png"
        guard let data = renderer.uiImage?.pngData(),
              (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }
}
