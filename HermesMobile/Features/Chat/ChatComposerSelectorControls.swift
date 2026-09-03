import SwiftUI
import UIKit

struct ComposerWorkspaceSelectorButton: View {
    let title: String
    let isDisabled: Bool
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ComposerInlineControlLabel(
                title: title,
                systemImage: "folder",
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        }
        .buttonStyle(.chatTactile(.compactControl))
        .disabled(isDisabled)
        .accessibilityLabel("Choose workspace path")
    }
}

struct ComposerProfileSelectorMenu: View {
    let profileOptions: [ProfileSummary]
    let selectedProfileName: String?
    let selectedProfileTitle: String
    /// Single-profile servers reject switches (#24), so the control is a plain
    /// label: no chevron, no menu, no button trait.
    let isStatic: Bool
    let isDisabled: Bool
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onSelectProfile: (ProfileSummary) -> Void

    var body: some View {
        if isStatic {
            ComposerInlineControlLabel(
                title: selectedProfileTitle,
                systemImage: "person.crop.circle",
                showsChevron: false,
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Profile: \(selectedProfileTitle)"))
        } else {
            profileMenu
        }
    }

    private var profileMenu: some View {
        Menu {
            if profileOptions.isEmpty {
                Text("No profiles available")
            } else {
                Section("Profile") {
                    ForEach(profileOptions, id: \.self) { profile in
                        Button {
                            onSelectProfile(profile)
                        } label: {
                            if profile.name == selectedProfileName {
                                Label(profile.displayName, systemImage: "checkmark")
                            } else {
                                Text(profile.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            ComposerInlineControlLabel(
                title: selectedProfileTitle,
                systemImage: "person.crop.circle",
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        }
        .buttonStyle(.chatTactile(.compactControl))
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel("Choose profile")
    }
}

struct ComposerModelEffortMenu: View {
    let selection: ComposerModelEffortSelection
    let modelGroups: [ModelCatalogGroup]
    let favoriteModelKeys: [ModelFavoriteKey]
    let recentModelKeys: [ModelFavoriteKey]
    let isDisabled: Bool
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onSelectModel: (ModelCatalogOption) -> Void
    let onSelectEffort: (String) -> Void
    let onShowAllModels: () -> Void

    var body: some View {
        // UIKit needs the nested menu's full geometry before presentation. Deferring
        // this tree makes the first submenu expansion visibly re-anchor.
        ChatUIKitMenuButton(loadsMenuEagerly: true) {
            HStack(spacing: 5) {
                if ProviderGlyphKind.resolve(providerID: selection.modelProviderID) != nil {
                    ProviderGlyph(providerID: selection.modelProviderID)
                        .frame(width: 15, height: 15)
                }

                Text(selection.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(controlFont)
                    .layoutPriority(1)

                Image(systemName: "chevron.down")
                    .font(chevronFont)
            }
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, ComposerInlineControlLabel.horizontalPadding)
            .frame(minHeight: ComposerInlineControlLabel.minimumHeight)
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
            }
        } menu: {
            makeMenu()
        }
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func makeMenu() -> UIMenu {
        var children: [UIMenuElement] = [modelMenu]
        if selection.showsEffortControl {
            children.append(effortMenu)
        }
        return UIMenu(children: children)
    }

    private var modelMenu: UIMenu {
        var children: [UIMenuElement] = []

        if !favoriteOptions.isEmpty {
            children.append(modelSection(title: String(localized: "Favorites"), options: favoriteOptions))
        }
        if !recentOptions.isEmpty {
            children.append(modelSection(title: String(localized: "Recent"), options: recentOptions))
        }
        if favoriteOptions.isEmpty && recentOptions.isEmpty {
            children.append(modelSection(title: "", options: [selection.model]))
        }

        children.append(UIMenu(
            options: [.displayInline],
            children: [
                UIAction(title: String(localized: "All Models...")) { _ in
                    Task { @MainActor in
                        await Task.yield()
                        onShowAllModels()
                    }
                }
            ]
        ))

        return UIMenu(
            title: String(localized: "Model"),
            subtitle: selection.model.displayName,
            children: children
        )
    }

    private var effortMenu: UIMenu {
        UIMenu(
            title: String(localized: "Effort"),
            subtitle: selection.effortTitle,
            children: selection.effortOptions.map { option in
                UIAction(
                    title: option.title,
                    state: selection.committedEffort == option.id ? .on : .off
                ) { _ in
                    Task { @MainActor in
                        onSelectEffort(option.id)
                    }
                }
            }
        )
    }

    private func modelSection(title: String, options: [ModelCatalogOption]) -> UIMenu {
        UIMenu(
            title: title,
            options: [.displayInline],
            children: options.map(modelAction)
        )
    }

    private func modelAction(_ option: ModelCatalogOption) -> UIAction {
        UIAction(
            title: option.displayName,
            state: option.matchesSelection(
                modelID: selection.model.id,
                providerID: selection.modelProviderID
            ) ? .on : .off
        ) { _ in
            Task { @MainActor in
                onSelectModel(option)
            }
        }
    }

    private var favoriteOptions: [ModelCatalogOption] {
        ModelFavoritesStore.visibleFavoriteOptions(
            in: modelGroups,
            favoriteKeys: favoriteModelKeys
        )
    }

    private var recentOptions: [ModelCatalogOption] {
        ModelRecentsStore.visibleRecentOptions(
            in: modelGroups,
            recentKeys: recentModelKeys,
            favoriteKeys: favoriteModelKeys
        )
    }

    private var accessibilityLabel: Text {
        Text(verbatim: selection.title)
    }
}

struct ComposerModelEffortSelection: Equatable, Sendable {
    let model: ModelCatalogOption
    let effort: String?
    let supportedEfforts: [String]?
    let supportsEffort: Bool?

    var modelProviderID: String? {
        model.providerID ?? model.id.modelIDProviderPrefix
    }

    var showsEffortControl: Bool {
        ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: supportsEffort,
            supportedEfforts: supportedEfforts
        )
    }

    var effortOptions: [ReasoningEffortOption] {
        ReasoningEffortOption.options(forSupportedEfforts: supportedEfforts)
    }

    var staticEffort: ReasoningEffortOption? {
        ReasoningEffortOption.singleOption(forSupportedEfforts: supportedEfforts)
    }

    var committedEffort: String? {
        guard showsEffortControl else { return nil }
        return staticEffort?.id ?? normalizedEffort(effort)
    }

    var effortTitle: String? {
        guard showsEffortControl else { return nil }
        guard let effort = committedEffort else { return String(localized: "Reasoning") }
        return ReasoningEffortOption.title(for: effort)
    }

    var title: String {
        guard let effortTitle else { return model.displayName }
        return "\(model.displayName) · \(effortTitle)"
    }

    private func normalizedEffort(_ effort: String?) -> String? {
        guard let effort else { return nil }
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

/// Quiet toolbar-row control: icon, one-line title, optional chevron, no pill
/// background, so the row reads as one surface. 44 pt tall for the hit target.
private struct ComposerInlineControlLabel: View {
    static let minimumHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 6

    let title: String
    let systemImage: String
    var showsChevron = true
    let color: Color
    let controlFont: Font
    let chevronFont: Font

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(controlFont)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(controlFont)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(chevronFont)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(minHeight: Self.minimumHeight)
        .contentShape(Rectangle())
    }
}

struct ReasoningEffortOption: Identifiable, CaseIterable {
    let id: String
    let title: String

    static let allCases: [ReasoningEffortOption] = [
        ReasoningEffortOption(id: "none", title: String(localized: "None")),
        ReasoningEffortOption(id: "minimal", title: String(localized: "Minimal")),
        ReasoningEffortOption(id: "low", title: String(localized: "Low")),
        ReasoningEffortOption(id: "medium", title: String(localized: "Medium")),
        ReasoningEffortOption(id: "high", title: String(localized: "High")),
        ReasoningEffortOption(id: "xhigh", title: String(localized: "XHigh"))
    ]

    static func title(for effort: String) -> String {
        allCases.first(where: { $0.id == effort })?.title
            ?? effort.capitalized
    }

    /// Menu options for a server-provided effort vocabulary (issue #18).
    /// `nil` or empty → the full static list (older servers / defensive fallback;
    /// an empty list also means `supports_reasoning_effort == false`, which hides
    /// the control before this is ever rendered). Unknown ids are kept with a
    /// capitalized title so a newer server's vocabulary still works.
    static func options(forSupportedEfforts supportedEfforts: [String]?) -> [ReasoningEffortOption] {
        guard let supportedEfforts, !supportedEfforts.isEmpty else { return allCases }

        var seen = Set<String>()
        return supportedEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { id in
                allCases.first(where: { $0.id == id })
                    ?? ReasoningEffortOption(id: id, title: id.capitalized)
            }
    }

    /// The lone effort when the server vocabulary leaves nothing to choose, so the
    /// composer can render a static label instead of a one-item menu.
    static func singleOption(forSupportedEfforts supportedEfforts: [String]?) -> ReasoningEffortOption? {
        let options = options(forSupportedEfforts: supportedEfforts)
        return options.count == 1 ? options[0] : nil
    }

    /// Whether the composer should show the effort control at all (issue #18).
    /// `supports_reasoning_effort == false` hides it; older servers (both fields
    /// absent) keep today's behavior and show it.
    static func showsEffortControl(
        supportsReasoningEffort: Bool?,
        supportedEfforts: [String]?
    ) -> Bool {
        if let supportsReasoningEffort { return supportsReasoningEffort }
        if let supportedEfforts { return !supportedEfforts.isEmpty }
        return true
    }
}
