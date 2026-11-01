import SwiftUI

/// One third-party license notice bundled in the app's `ThirdPartyNotices/` folder (#1411).
struct AcknowledgementNotice: Hashable {
    let name: String
    let url: URL

    /// The bundle's notices sorted by name. Reads file names only; a notice's text is read when its
    /// page opens. `NOTICE.txt` is the folder's index, not a notice.
    static func loadAll(bundle: Bundle = .main) -> [AcknowledgementNotice] {
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: "ThirdPartyNotices") ?? []
        return urls
            .filter { $0.lastPathComponent != "NOTICE.txt" }
            .map { AcknowledgementNotice(name: displayName(for: $0), url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The project's home page, from `Package.resolved` (Lucide is a bundled asset, not a package).
    var projectURL: URL? {
        switch name {
        case "Highlightr": URL(staticString: "https://github.com/raspu/Highlightr")
        case "KeychainAccess": URL(staticString: "https://github.com/kishikawakatsumi/KeychainAccess")
        case "LDSwiftEventSource": URL(staticString: "https://github.com/LaunchDarkly/swift-eventsource")
        case "Lucide icons": URL(staticString: "https://github.com/lucide-icons/lucide")
        case "MarkdownUI": URL(staticString: "https://github.com/gonzalezreal/swift-markdown-ui")
        case "NetworkImage": URL(staticString: "https://github.com/gonzalezreal/NetworkImage")
        case "Splash": URL(staticString: "https://github.com/JohnSundell/Splash")
        case "swift-cmark": URL(staticString: "https://github.com/swiftlang/swift-cmark")
        case "SwiftMath": URL(staticString: "https://github.com/mgriebling/SwiftMath")
        default: nil
        }
    }

    /// `MarkdownUI-LICENSE.txt` → "MarkdownUI".
    private static func displayName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in ["-LICENSE", "-COPYING"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name == "LucideIcons" ? "Lucide icons" : name
    }
}

/// About → Acknowledgements: the bundled notices, each pushing its license text.
struct SettingsAcknowledgementsPage: View {
    private static let notices = AcknowledgementNotice.loadAll()

    var body: some View {
        List(Self.notices, id: \.url) { notice in
            NavigationLink(notice.name) {
                AcknowledgementNoticePage(notice: notice)
            }
        }
        .settingsPage(String(localized: "Acknowledgements"))
    }
}

/// One notice's verbatim, selectable license text, read off the main actor when the page opens.
private struct AcknowledgementNoticePage: View {
    let notice: AcknowledgementNotice
    @State private var text: Result<String, any Error>?

    var body: some View {
        Group {
            switch text {
            case .failure:
                ContentUnavailableView(String(localized: "Couldn’t read this notice"), systemImage: "doc.text")
            case .success(let text):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let projectURL = notice.projectURL {
                            Link((projectURL.host() ?? "") + projectURL.path(), destination: projectURL)
                                .font(.footnote)
                        }
                        Text(verbatim: text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            case nil:
                Color.clear
            }
        }
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: notice.url) {
            let url = notice.url
            let read = await Task.detached(priority: .userInitiated) {
                Result { try String(contentsOf: url, encoding: .utf8) }
            }.value
            guard !Task.isCancelled else { return }
            text = read
        }
    }
}
