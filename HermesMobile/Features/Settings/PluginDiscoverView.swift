import ImageIO
import SwiftUI

/// The Plugins page's Discover tab (#1582): the host's catalog by tier, with category filters and
/// on-device search. Without a search or category, Official is a shelf of large banners, because all
/// of it has one; only about a quarter of the rest does, so those are rows with small thumbnails.
struct PluginDiscoverSections: View {
    let model: PluginsModel
    let profile: String

    @State private var reviewing: HermesCatalogEntry?

    var body: some View {
        switch model.catalog {
        case .idle, .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading the catalog…")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load the Catalog", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.loadCatalog() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            categoryChips
            list
                .sheet(item: $reviewing) { PluginInstallSheet(model: model, profile: profile, entry: $0) }
        }
    }

    @ViewBuilder
    private var list: some View {
        let groups = model.discoverGroups
        let installed = model.installedCatalogNames
        if groups.isEmpty {
            ContentUnavailableView("No Plugins Match", systemImage: "puzzlepiece.extension")
                .listRowBackground(Color.clear)
        }
        ForEach(groups) { group in
            Section {
                if group.tier == .official, model.discoverCategory == nil, model.query.isEmpty {
                    PluginShelf(entries: group.entries, model: model, profile: profile)
                } else {
                    ForEach(group.entries) { entry in
                        NavigationLink {
                            PluginCatalogDetail(entry: entry, model: model, profile: profile)
                        } label: {
                            PluginCatalogRow(entry: entry, isInstalled: installed?.contains(entry.name), isTooNew: model.isTooNew(entry)) {
                                reviewing = entry
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(verbatim: group.tier.title)
                    Text(verbatim: "\(group.entries.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PluginChip(title: String(localized: "All"), isSelected: model.discoverCategory == nil) { model.discoverCategory = nil }
                ForEach(model.discoverCategories, id: \.self) { category in
                    PluginChip(title: Self.title(of: category), isSelected: model.discoverCategory == category) {
                        model.discoverCategory = category
                    }
                }
            }
        }
        .scrollClipDisabled()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// A category's label. One the host adds later reads as its own name, capitalized.
    static func title(of category: String) -> String {
        switch category {
        case "tools": String(localized: "Tools")
        case "memory": String(localized: "Memory")
        case "web": String(localized: "Web")
        case "models": String(localized: "Models")
        case "voice": String(localized: "Voice")
        case "automation": String(localized: "Automation")
        case "platform": String(localized: "Platforms")
        case "general": String(localized: "General")
        case "desktop": String(localized: "Desktop")
        default: category.capitalized
        }
    }
}

/// One filter chip, shared by both tabs.
struct PluginChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                .background(isSelected ? Color.primary : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Official shelf: large banners that scroll sideways. It lays out only what's near the screen.
private struct PluginShelf: View {
    let entries: [HermesCatalogEntry]
    let model: PluginsModel
    let profile: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(entries) { entry in
                    NavigationLink {
                        PluginCatalogDetail(entry: entry, model: model, profile: profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            PluginCatalogImage(url: entry.image, fallback: entry.title, size: CGSize(width: 228, height: 114), cornerRadius: 12)
                            Text(verbatim: entry.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(verbatim: entry.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(width: 228, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

/// A dense catalog row. Get opens the review and never installs by itself.
private struct PluginCatalogRow: View {
    let entry: HermesCatalogEntry
    /// Nil until the shown Profile's list is read.
    let isInstalled: Bool?
    let isTooNew: Bool
    let onGet: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PluginCatalogImage(url: entry.image, fallback: entry.title, size: CGSize(width: 64, height: 32), cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: entry.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    /// Why this can't be installed, or that it already is, or Get.
    @ViewBuilder
    private var trailing: some View {
        if isInstalled == true {
            Text("Installed").font(.footnote).foregroundStyle(.secondary)
        } else if isInstalled == false, !isTooNew {
            Button("Get", action: onGet)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text("Get \(entry.title)"))
        }
    }

    private var details: String {
        var parts = [entry.maintainer]
        if entry.needsDesktop { parts.append(String(localized: "Needs Hermes Desktop")) }
        if isTooNew { parts.append(String(localized: "Needs Hermes \(entry.minimumHermes)")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One plugin's page: its banner, swipeable screenshots and facts, and the way to its review.
private struct PluginCatalogDetail: View {
    let entry: HermesCatalogEntry
    let model: PluginsModel
    let profile: String

    @State private var isReviewing = false

    /// Nil until the shown Profile's list is read.
    private var isInstalled: Bool? { model.installedCatalogNames?.contains(entry.name) }

    var body: some View {
        List {
            if entry.image != nil {
                PluginCatalogImage(url: entry.image, fallback: entry.title, size: nil, cornerRadius: 12)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !entry.screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(entry.screenshots, id: \.self) { url in
                            PluginCatalogImage(url: url, fallback: entry.title, size: CGSize(width: 210, height: 130), cornerRadius: 10)
                        }
                    }
                }
                .scrollClipDisabled()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            PluginCatalogReview(entry: entry, isTooNew: model.isTooNew(entry))
        }
        .listSectionSpacing(.compact)
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                isReviewing = true
            } label: {
                Text(isInstalled == true ? String(localized: "Installed on \(profile)") : String(localized: "Review and Install"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInstalled != false || model.isTooNew(entry))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $isReviewing) { PluginInstallSheet(model: model, profile: profile, entry: entry) }
    }
}

/// A catalog banner or screenshot, at a fixed `size`, or filling the width at the banners' usual 2:1
/// when it's nil. It loads when it appears and its download is cancelled when it scrolls away. Until
/// then, and for a plugin with no image, it shows a tile with the plugin's letter.
private struct PluginCatalogImage: View {
    /// Wide enough to stay sharp at the width of the largest iPhone.
    private static let fullWidth: CGFloat = 440

    let url: URL?
    let fallback: String
    let size: CGSize?
    let cornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        sized
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                let points = size.map { max($0.width, $0.height) } ?? Self.fullWidth
                let loaded = await PluginImageLoader.image(at: url, maxPixels: Int(points * displayScale))
                if !Task.isCancelled { image = loaded }
            }
    }

    @ViewBuilder
    private var sized: some View {
        if let size {
            content.frame(width: size.width, height: size.height)
        } else {
            Color.clear.aspectRatio(2, contentMode: .fit).overlay { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color(.tertiarySystemFill)
                .overlay {
                    Text(verbatim: String(fallback.prefix(1)).uppercased())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// Fetches and downsamples catalog images. The memory cache is bounded and clears itself under
/// pressure, and nothing reaches the disk. The session refuses Low Data Mode, so an image then just
/// stays a tile, and it sends no cookies or sign-ins: these requests go to GitHub, not the user's host.
enum PluginImageLoader {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// Nil when it can't be fetched or decoded, or the caller was cancelled. Failures aren't cached.
    static func image(at url: URL, maxPixels: Int) async -> UIImage? {
        let key = "\(maxPixels)|\(url.absoluteString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Off the main thread, and it isn't worth finishing once the row has scrolled away.
        guard !Task.isCancelled, let image = await Task.detached(priority: .utility, operation: {
            downsample(data, maxPixels: maxPixels)
        }).value else { return nil }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// The first frame, which is all a GIF shows, decoded at the size it's drawn.
    private static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
