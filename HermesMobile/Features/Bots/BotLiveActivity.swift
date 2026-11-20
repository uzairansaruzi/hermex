import CryptoKit
import SwiftUI
import UIKit

extension AgentRunActivityBot {
    init?(_ destination: BotDestination, avatarFile: String? = nil) {
        guard let url = HermesDeepLink.botURL(for: destination) else { return nil }
        self.init(key: "bot:\(destination.connectionID.uuidString):\(destination.profile)",
                  destinationURL: url, avatarFile: avatarFile)
    }
}

@MainActor enum BotLiveActivity {
    nonisolated static func countChips(plan: HermesPlan?, workers: Int, tools: Int = 0) -> [String] {
        var chips: [String] = []
        if let plan, !plan.isFinished {
            chips.append(String(localized: "Plan \(min(plan.completedCount + 1, plan.items.count)) of \(plan.items.count)"))
        }
        if workers > 0 { chips.append(String(localized: "\(workers) workers")) }
        if tools > 0 { chips.append(String(localized: "\(tools) tools")) }
        return chips
    }

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
        .environment(\.colorScheme, .dark))
        renderer.scale = 3
        let digest = SHA256.hash(data: Data(profile.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "\(destination.connectionID.uuidString)-\(digest).png"
        guard let data = renderer.uiImage?.pngData(),
              (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }
}
