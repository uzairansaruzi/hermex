import CryptoKit
import SwiftUI
import WidgetKit

/// Keeps the Bot widget's snapshot (#1643) in step with each server's roster. The Bots inbox hands
/// it every roster it reads (`publish`) and, once avatars load, the photos it has (`renderAvatars`);
/// `AuthManager.removeServer` drops a server (`remove`). A sign-out keeps the server's bots, as
/// `HermesProfileNameCache` does, and a replaced connection's next roster read overwrites them.
/// Main-actor, so writes are serialized.
@MainActor final class BotWidgetPublisher {
    static let shared = BotWidgetPublisher(file: BotWidgetSnapshotFile.shared)

    private let file: BotWidgetSnapshotFile?
    private let serverTitle: @MainActor (URL) -> String
    private let reloadWidget: () -> Void
    private let configuredBots: () async -> [BotWidgetDestination]

    init(file: BotWidgetSnapshotFile?,
         serverTitle: @escaping @MainActor (URL) -> String = BotWidgetPublisher.registryTitle,
         reloadWidget: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: BotWidgetSnapshot.widgetKind) },
         configuredBots: @escaping () async -> [BotWidgetDestination] = BotWidgetPublisher.currentConfigurations) {
        self.file = file
        self.serverTitle = serverTitle
        self.reloadWidget = reloadWidget
        self.configuredBots = configuredBots
    }

    /// Replaces `server`'s bots with `profiles`, an empty roster dropping the server, and reloads
    /// the widget only when that changed something.
    func publish(_ profiles: [BotProfile], server: URL) {
        guard let file else { return }
        let key = BotHistoryCache.Scope.key(server)
        let bots = profiles.prefix(BotWidgetSnapshot.maxBotsPerServer).map {
            BotWidgetSnapshot.Bot(profile: $0.id, title: $0.name, avatar: Self.avatarName(serverKey: key, profile: $0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let current = file.read()
        var snapshot = current
        let entry = BotWidgetSnapshot.Server(serverKey: key, title: serverTitle(server), bots: bots)
        if let index = snapshot.servers.firstIndex(where: { $0.serverKey == key }) {
            if bots.isEmpty { snapshot.servers.remove(at: index) } else { snapshot.servers[index] = entry }
        } else if !bots.isEmpty {
            snapshot.servers.append(entry)
        }
        guard snapshot != current, snapshot.servers.count <= BotWidgetSnapshot.maxServers,
              (try? file.write(snapshot)) != nil else { return }
        reloadWidget()
    }

    /// Renders the avatar of each bot on `server` that a widget is configured for, unless its look
    /// revision already has a file, and deletes the server's other avatar files. A photo bot whose
    /// photo hasn't loaded is skipped, so its widget keeps the fallback face until the next read.
    func renderAvatars(_ profiles: [BotProfile], server: URL, photos: [String: UIImage]) async {
        guard let file else { return }
        let key = BotHistoryCache.Scope.key(server)
        let wanted = Set(await configuredBots().filter { $0.serverKey == key }.map(\.profile))
        var keep: Set<String> = []
        var rendered = false
        for profile in profiles where wanted.contains(profile.id) {
            let name = Self.avatarName(serverKey: key, profile: profile)
            keep.insert(name)
            let isCurrent = profile.lookRevision != nil
                && [false, true].allSatisfy { FileManager.default.fileExists(atPath: file.avatarURL(name, dark: $0).path) }
            let photo = photos[profile.id]
            guard !isCurrent, !(profile.isPhoto && photo == nil) else { continue }
            try? FileManager.default.createDirectory(at: file.avatarDirectory, withIntermediateDirectories: true)
            for dark in [false, true] {
                guard let data = Self.avatar(profile, photo: photo, dark: dark) else { continue }
                rendered = (try? data.write(to: file.avatarURL(name, dark: dark), options: .atomic)) != nil || rendered
            }
        }
        let prefix = Self.avatarPrefix(serverKey: key)
        for url in (try? FileManager.default.contentsOfDirectory(at: file.avatarDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) && !keep.contains(where: { url.lastPathComponent.hasPrefix("\($0)-") }) {
            try? FileManager.default.removeItem(at: url)
        }
        if rendered { reloadWidget() }
    }

    /// Drops a removed server's bots and avatar files.
    func remove(server: URL) {
        guard let file else { return }
        let key = BotHistoryCache.Scope.key(server)
        let prefix = Self.avatarPrefix(serverKey: key)
        for url in (try? FileManager.default.contentsOfDirectory(at: file.avatarDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
        var snapshot = file.read()
        guard snapshot.servers.contains(where: { $0.serverKey == key }) else { return }
        snapshot.servers.removeAll { $0.serverKey == key }
        guard (try? file.write(snapshot)) != nil else { return }
        reloadWidget()
    }

    /// `<server key prefix>-<Profile digest>-<look revision>`, so a new look gets a new file.
    static func avatarName(serverKey: String, profile: BotProfile) -> String {
        let digest = SHA256.hash(data: Data(profile.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(avatarPrefix(serverKey: serverKey))\(digest)-\(profile.lookRevision.map(String.init) ?? "u")"
    }

    private static func avatarPrefix(serverKey: String) -> String { "\(serverKey.prefix(16))-" }

    /// The photo, else the drawn face, as `BotLiveActivity.writeAvatar` renders them.
    private static func avatar(_ profile: BotProfile, photo: UIImage?, dark: Bool) -> Data? {
        let size: CGFloat = 76
        let renderer = ImageRenderer(content: Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                BotAvatarMarkView(name: profile.id, appearance: BotProfileAppearance(profile: profile), size: size)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    /// The server's display name, or a neutral title when it is empty or just repeats the host,
    /// so the app group never holds a host name.
    static func registryTitle(for server: URL) -> String {
        let name = ServerRegistry.shared.servers.first { $0.id == server.absoluteString }?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = name.lowercased()
        let addresses = [server.host, server.absoluteString, server.host.map { "\($0):\(server.port ?? 0)" }]
            .compactMap { $0?.lowercased() }
        guard !name.isEmpty, !addresses.contains(lowered) else { return String(localized: "Server") }
        return name
    }

    /// The bots the Home Screen's Bot widgets are configured with.
    static func currentConfigurations() async -> [BotWidgetDestination] {
        let widgets = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return widgets.filter { $0.kind == BotWidgetSnapshot.widgetKind }.flatMap {
            $0.widgetConfigurationIntent(of: BotWidgetConfigurationIntent.self)?.destinations ?? []
        }
    }
}
