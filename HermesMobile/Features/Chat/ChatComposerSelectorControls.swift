import SwiftUI
import UIKit

struct ComposerWorkspaceSelectorButton: View {
    let title: String
    let isDisabled: Bool
    let lineLimit: Int
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ComposerSecondaryBarLabel(
                title: title,
                systemImage: "folder",
                lineLimit: lineLimit,
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding,
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isDisabled)
        .accessibilityLabel("Choose workspace path")
    }
}

struct ComposerProfileSelectorMenu: View {
    let profileOptions: [ProfileSummary]
    let selectedProfileName: String?
    let selectedProfileTitle: String
    let isDisabled: Bool
    let lineLimit: Int
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onSelectProfile: (ProfileSummary) -> Void

    var body: some View {
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
            ComposerSecondaryBarLabel(
                title: selectedProfileTitle,
                systemImage: "person.crop.circle",
                lineLimit: lineLimit,
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding,
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel("Choose profile")
    }
}

struct ComposerModelMenu: View {
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool
    let favoriteModelKeys: [ModelFavoriteKey]
    let recentModelKeys: [ModelFavoriteKey]
    let isDisabled: Bool
    let maxWidth: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onSelectModel: (ModelCatalogOption) -> Void
    let onShowAllModels: () -> Void

    var body: some View {
        ChatUIKitMenuButton(horizontalPadding: 0, verticalPadding: 14) {
            ComposerMetaControlLabel(
                title: selectedModelTitle,
                systemImage: nil,
                maxWidth: maxWidth,
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        } menu: {
            makeModelMenu()
        }
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel("Select model")
    }

    private func makeModelMenu() -> UIMenu {
        if isLoadingModels {
            return UIMenu(children: [disabledMenuAction(title: String(localized: "Loading models..."))])
        }

        var children: [UIMenuElement] = []
        if modelGroups.isEmpty && favoriteOptions.isEmpty && recentOptions.isEmpty && compactOptions.isEmpty {
            children.append(disabledMenuAction(title: String(localized: "No catalog models")))
        }

        if !favoriteOptions.isEmpty {
            children.append(modelSection(title: String(localized: "Favorites"), options: favoriteOptions))
        }

        if !recentOptions.isEmpty {
            children.append(modelSection(title: String(localized: "Recent"), options: recentOptions))
        }

        children.append(UIMenu(
            title: String(localized: "Model"),
            options: [.displayInline],
            children: compactOptions.map(modelAction)
                + [
                    UIAction(title: String(localized: "All Models...")) { _ in
                        Task { @MainActor in
                            await Task.yield()
                            onShowAllModels()
                        }
                    }
                ]
        ))

        return UIMenu(children: children)
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
            state: isSelected(option) ? .on : .off
        ) { _ in
            Task { @MainActor in
                onSelectModel(option)
            }
        }
    }

    private func disabledMenuAction(title: String) -> UIAction {
        let action = UIAction(title: title) { _ in }
        action.attributes.insert(.disabled)
        return action
    }

    private var compactOptions: [ModelCatalogOption] {
        let allModels = modelGroups.flatMap(\.models)
        let favoriteKeys = Set(favoriteOptions.map(\.favoriteKey))
        let recentKeys = Set(recentOptions.map(\.favoriteKey))
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelCatalogOption] = []

        func append(_ option: ModelCatalogOption?) {
            guard let option,
                  !favoriteKeys.contains(option.favoriteKey),
                  !recentKeys.contains(option.favoriteKey),
                  seen.insert(option.favoriteKey).inserted else { return }
            result.append(option)
        }

        append(selectedModelOption(in: allModels))

        return result
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

    private func selectedModelOption(in options: [ModelCatalogOption]) -> ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }

        if let selectedModelProviderID {
            return options.firstMatchingSelection(
                modelID: selectedModelID,
                providerID: selectedModelProviderID
            )
            ?? ModelCatalogOption(
                id: selectedModelID,
                displayName: selectedModelID,
                providerID: selectedModelProviderID
            )
        }

        return options.firstMatchingSelection(modelID: selectedModelID, providerID: nil)
            ?? ModelCatalogOption(
                id: selectedModelID,
                displayName: selectedModelID,
                providerID: nil
            )
    }

    private func isSelected(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(modelID: selectedModelID, providerID: selectedModelProviderID)
    }
}

struct ComposerReasoningMenu: View {
    let selectedReasoningEffort: String?
    /// Server-provided effort vocabulary for the current model; `nil` falls
    /// back to the full static list (older servers, issue #18).
    let supportedEfforts: [String]?
    let reasoningTitle: String
    let isDisabled: Bool
    let width: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onSelectReasoningEffort: (String) -> Void

    var body: some View {
        ChatUIKitMenuButton(horizontalPadding: 0, verticalPadding: 14) {
            ComposerMetaControlLabel(
                title: reasoningTitle,
                systemImage: "lucide.brain",
                minWidth: width,
                maxWidth: width,
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        } menu: {
            makeReasoningMenu()
        }
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel("Select reasoning effort")
    }

    private func makeReasoningMenu() -> UIMenu {
        UIMenu(
            title: String(localized: "Reasoning"),
            options: [.displayInline],
            children: ReasoningEffortOption.options(forSupportedEfforts: supportedEfforts).map { option in
                UIAction(
                    title: option.title,
                    state: selectedReasoningEffort == option.id ? .on : .off
                ) { _ in
                    Task { @MainActor in
                        onSelectReasoningEffort(option.id)
                    }
                }
            }
        )
    }
}

private struct ComposerMetaControlLabel: View {
    @ScaledMetric(relativeTo: .footnote) private var brainIconSize: CGFloat = 13

    let title: String
    let systemImage: String?
    var minWidth: CGFloat?
    let maxWidth: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                if systemImage == "lucide.brain" {
                    LucideBrainIcon()
                        .frame(width: brainIconSize, height: brainIconSize)
                } else {
                    Image(systemName: systemImage)
                        .font(controlFont)
                }
            }

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(controlFont)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(chevronFont)
        }
        .foregroundStyle(color)
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
        .transaction { transaction in
            transaction.animation = nil
        }
        .chatMinimumHitTarget(horizontalPadding: 0, verticalPadding: 14, in: Rectangle())
    }
}

private struct ComposerSecondaryBarLabel: View {
    let title: String
    let systemImage: String
    let lineLimit: Int
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let color: Color
    let controlFont: Font
    let chevronFont: Font

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(controlFont)

            Text(title)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .font(controlFont)

            Image(systemName: "chevron.down")
                .font(chevronFont)
        }
        .foregroundStyle(color)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: .ultraThinMaterial,
            in: Capsule()
        )
        .clipShape(Capsule())
        .chatMinimumHitTarget(in: Capsule())
    }
}

private struct LucideBrainIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 24, size.height / 24)
            let xOffset = (size.width - (24 * scale)) / 2
            let yOffset = (size.height - (24 * scale)) / 2

            context.translateBy(x: xOffset, y: yOffset)
            context.scaleBy(x: scale, y: scale)

            let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            for path in Self.paths {
                context.stroke(path, with: .foreground, style: strokeStyle)
            }
        }
        .accessibilityHidden(true)
    }

    private static let paths: [Path] = [
        Path { path in
            path.move(to: CGPoint(x: 12, y: 18))
            path.addLine(to: CGPoint(x: 12, y: 5))
        },
        Path { path in
            path.move(to: CGPoint(x: 15, y: 13))
            path.addCurve(
                to: CGPoint(x: 12, y: 9),
                control1: CGPoint(x: 13.4, y: 12.4),
                control2: CGPoint(x: 12, y: 10.8)
            )
            path.addCurve(
                to: CGPoint(x: 9, y: 13),
                control1: CGPoint(x: 12, y: 10.8),
                control2: CGPoint(x: 10.6, y: 12.4)
            )
        },
        Path { path in
            path.move(to: CGPoint(x: 17.6, y: 6.5))
            path.addCurve(to: CGPoint(x: 12, y: 5), control1: CGPoint(x: 18.2, y: 3.7), control2: CGPoint(x: 14.1, y: 2.4))
            path.addCurve(to: CGPoint(x: 6.4, y: 6.5), control1: CGPoint(x: 9.9, y: 2.4), control2: CGPoint(x: 5.8, y: 3.7))
        },
        Path { path in
            path.move(to: CGPoint(x: 18, y: 5.1))
            path.addCurve(to: CGPoint(x: 20.5, y: 10.9), control1: CGPoint(x: 21, y: 5.6), control2: CGPoint(x: 22, y: 8.7))
        },
        Path { path in
            path.move(to: CGPoint(x: 18, y: 18))
            path.addCurve(to: CGPoint(x: 20, y: 10.5), control1: CGPoint(x: 22, y: 17.1), control2: CGPoint(x: 22.7, y: 12.4))
        },
        Path { path in
            path.move(to: CGPoint(x: 20, y: 17.5))
            path.addCurve(to: CGPoint(x: 12, y: 18), control1: CGPoint(x: 19.4, y: 22.5), control2: CGPoint(x: 12.6, y: 22.8))
            path.addCurve(to: CGPoint(x: 4, y: 17.5), control1: CGPoint(x: 11.4, y: 22.8), control2: CGPoint(x: 4.6, y: 22.5))
        },
        Path { path in
            path.move(to: CGPoint(x: 6, y: 18))
            path.addCurve(to: CGPoint(x: 4, y: 10.5), control1: CGPoint(x: 2, y: 17.1), control2: CGPoint(x: 1.3, y: 12.4))
        },
        Path { path in
            path.move(to: CGPoint(x: 6, y: 5.1))
            path.addCurve(to: CGPoint(x: 3.5, y: 10.9), control1: CGPoint(x: 3, y: 5.6), control2: CGPoint(x: 2, y: 8.7))
        }
    ]
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
