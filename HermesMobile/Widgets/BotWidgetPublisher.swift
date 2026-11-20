import CryptoKit
import SwiftUI
import WidgetKit

@MainActor final class BotWidgetPublisher {
    static let shared = BotWidgetPublisher(file: BotWidgetSnapshotFile.shared)

    private let file: BotWidgetSnapshotFile?
    private let serverTitle: @MainActor (URL) -> String?
    private let reloadWidget: () -> Void
    private let configuredBots: () async -> [BotWidgetDestination]?
    private var renderGenerations: [String: Int] = [:]

    init(file: BotWidgetSnapshotFile?,
         serverTitle: @escaping @MainActor (URL) -> String? = BotWidgetPublisher.registryTitle,
         reloadWidget: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: BotWidgetSnapshot.widgetKind) },
         configuredBots: @escaping () async -> [BotWidgetDestination]? = BotWidgetPublisher.currentConfigurations) {
        self.file = file
        self.serverTitle = serverTitle
        self.reloadWidget = reloadWidget
        self.configuredBots = configuredBots
    }

    func publish(_ profiles: [BotProfile], server: URL, connectionID: UUID) {
        guard let file, let title = serverTitle(server) else { return }
        let key = BotHistoryCache.Scope.key(server)
        let bots = profiles.prefix(BotWidgetSnapshot.maxBotsPerServer).map {
            BotWidgetSnapshot.Bot(profile: $0.id, title: $0.name, avatar: Self.avatarName(serverKey: key, profile: $0, connectionID: connectionID))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let current = file.read()
        var snapshot = current
        let entry = BotWidgetSnapshot.Server(serverKey: key, title: title, bots: bots)
        if let index = snapshot.servers.firstIndex(where: { $0.serverKey == key }) {
            if bots.isEmpty { snapshot.servers.remove(at: index) } else { snapshot.servers[index] = entry }
        } else if !bots.isEmpty {
            snapshot.servers.append(entry)
        }
        guard snapshot != current, snapshot.servers.count <= BotWidgetSnapshot.maxServers,
              (try? file.write(snapshot)) != nil else { return }
        reloadWidget()
    }

    func renderAvatars(_ profiles: [BotProfile], server: URL, connectionID: UUID, photos: [String: UIImage]) async {
        guard let file else { return }
        let key = BotHistoryCache.Scope.key(server)
        let generation = renderGenerations[key, default: 0] + 1
        renderGenerations[key] = generation
        guard let configured = await configuredBots(), renderGenerations[key] == generation else { return }
        let wanted = Set(configured.filter { $0.serverKey == key }.map(\.profile))
        var keep: Set<String> = []
        var rendered = false
        for profile in profiles where wanted.contains(profile.id) {
            let name = Self.avatarName(serverKey: key, profile: profile, connectionID: connectionID)
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

    func forgetAvatar(server: URL, profile: String) {
        guard let file else { return }
        let prefix = Self.avatarPrefix(serverKey: BotHistoryCache.Scope.key(server)) + Self.profileDigest(profile) + "-"
        for url in (try? FileManager.default.contentsOfDirectory(at: file.avatarDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove(server: URL) {
        guard let file else { return }
        let key = BotHistoryCache.Scope.key(server)
        renderGenerations[key, default: 0] += 1
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

    static func avatarName(serverKey: String, profile: BotProfile, connectionID: UUID) -> String {
        let revision = profile.lookRevision.map(String.init) ?? "u"
        return "\(avatarPrefix(serverKey: serverKey))\(profileDigest(profile.id))-\(digest(connectionID.uuidString, bytes: 4))-\(revision)"
    }

    private static func profileDigest(_ profile: String) -> String { digest(profile, bytes: 8) }

    private static func digest(_ text: String, bytes: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func avatarPrefix(serverKey: String) -> String { "\(serverKey.prefix(16))-" }

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

    static func registryTitle(for server: URL) -> String? {
        guard let account = ServerRegistry.shared.servers.first(where: { $0.id == server.absoluteString }) else { return nil }
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = name.lowercased()
        let addresses = [server.host, server.absoluteString, server.host.map { "\($0):\(server.port ?? 0)" }]
            .compactMap { $0?.lowercased() }
        guard !name.isEmpty, !addresses.contains(lowered) else { return String(localized: "Server") }
        return name
    }

    static func currentConfigurations() async -> [BotWidgetDestination]? {
        guard let widgets = try? await WidgetCenter.shared.currentConfigurations() else { return nil }
        return widgets.filter { $0.kind == BotWidgetSnapshot.widgetKind }.flatMap {
            $0.widgetConfigurationIntent(of: BotWidgetConfigurationIntent.self)?.destinations ?? []
        }
    }
}
