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
        ChatUIKitMenuButton {
            ComposerInlineControlLabel(
                title: selectedProfileTitle,
                systemImage: "person.crop.circle",
                color: color,
                controlFont: controlFont,
                chevronFont: chevronFont
            )
        } menu: {
            makeMenu()
        }
        .tint(color)
        .disabled(isDisabled)
        .accessibilityLabel("Choose profile")
    }

    func makeMenu() -> UIMenu {
        guard !profileOptions.isEmpty else {
            return UIMenu(children: [
                UIAction(
                    title: String(localized: "No profiles available"),
                    attributes: .disabled
                ) { _ in }
            ])
        }

        return UIMenu(children: [
            UIMenu(
                title: String(localized: "Profile"),
                options: [.displayInline],
                children: profileOptions.map { profile in
                    UIAction(
                        title: profile.displayName,
                        state: profile.name == selectedProfileName ? .on : .off
                    ) { _ in
                        Task { @MainActor in
                            onSelectProfile(profile)
                        }
                    }
                }
            )
        ])
    }
}

struct ComposerModelLabelButton: View {
    let showsTitle: Bool
    let selection: ComposerModelEffortSelection
    let isDisabled: Bool
    let color: Color
    let controlFont: Font
    let chevronFont: Font
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if ProviderGlyphKind.resolve(providerID: selection.modelProviderID) != nil {
                    ProviderGlyph(providerID: selection.modelProviderID)
                        .frame(width: 15, height: 15)
                } else if !showsTitle {
                    Image(systemName: "cpu")
                        .font(controlFont)
                }

                if showsTitle {
                    Text(selection.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(controlFont)
                        .layoutPriority(1)
                }

                Image(systemName: "chevron.down")
                    .font(chevronFont)
            }
            .foregroundStyle(color)
            .padding(.horizontal, ComposerInlineControlLabel.horizontalPadding)
            .frame(minHeight: ComposerInlineControlLabel.minimumHeight)
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .buttonStyle(.chatTactile(.compactControl))
        .disabled(isDisabled)
        .accessibilityLabel(Text(verbatim: selection.accessibilityTitle))
        .accessibilityHint(Text("Model settings"))
    }
}

struct ComposerApprovals: Equatable {
    let isYoloOn: Bool
    let offersModes: Bool
    let mode: String?
    let mayTurnOffYolo: Bool
    let isChanging: Bool
    let errorMessage: String?

    var value: String? {
        if mode == HermesApprovalMode.off.rawValue { return Self.title(for: .off) }
        if isYoloOn { return "YOLO" }
        guard let mode else { return nil }
        return HermesApprovalMode(rawValue: mode).map(Self.title(for:)) ?? mode.capitalized
    }

    var isYoloLocked: Bool { isYoloOn && !mayTurnOffYolo }

    var canTurnOffYolo: Bool { isYoloOn && mayTurnOffYolo }

    static func title(for mode: HermesApprovalMode) -> String {
        switch mode {
        case .smart: return String(localized: "Smart")
        case .manual: return String(localized: "Manual")
        case .off: return String(localized: "Off")
        }
    }
}

struct ComposerModelEffortSelection: Equatable, Sendable {
    let model: ModelCatalogOption
    let effort: String?
    let supportedEfforts: [String]?
    let supportsEffort: Bool?
    var sentEffort: String? = nil

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
        let title = ReasoningEffortOption.title(for: effort)
        guard let lowered = loweredEffort else { return title }
        return String(localized: "\(title) · sent as \(ReasoningEffortOption.title(for: lowered))")
    }

    var title: String {
        let modelLabel = ModelDisplayNames.displayLabel(for: model.id, displayName: model.displayName)
        guard committedEffort != nil, let effortTitle else { return modelLabel }
        return "\(modelLabel) · \(effortTitle)"
    }

    var accessibilityTitle: String {
        guard let effort = committedEffort, let lowered = loweredEffort else { return title }
        let picked = ReasoningEffortOption.title(for: effort), sent = ReasoningEffortOption.title(for: lowered)
        return String(localized: "\(ModelDisplayNames.displayLabel(for: model.id, displayName: model.displayName)), \(picked) effort, sent as \(sent)")
    }

    func replacingEffort(with level: String) -> Self {
        Self(model: model, effort: level, supportedEfforts: supportedEfforts, supportsEffort: supportsEffort)
    }

    private var loweredEffort: String? {
        guard let effort = committedEffort, let sent = normalizedEffort(sentEffort), sent != effort else { return nil }
        return sent
    }

    private func normalizedEffort(_ effort: String?) -> String? {
        guard let effort else { return nil }
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct ComposerInlineControlLabel: View {
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

    private static let titled = allCases + [
        ReasoningEffortOption(id: "max", title: String(localized: "Max")),
        ReasoningEffortOption(id: "ultra", title: String(localized: "Ultra"))
    ]

    static func title(for effort: String) -> String {
        titled.first(where: { $0.id == effort })?.title
            ?? effort.capitalized
    }

    static func shortTitle(for effort: String) -> String {
        switch effort {
        case "minimal": String(localized: "Min")
        case "medium": String(localized: "Med")
        default: title(for: effort)
        }
    }

    static func options(forSupportedEfforts supportedEfforts: [String]?) -> [ReasoningEffortOption] {
        guard let supportedEfforts, !supportedEfforts.isEmpty else { return allCases }

        var seen = Set<String>()
        return supportedEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { id in ReasoningEffortOption(id: id, title: title(for: id)) }
    }

    static func singleOption(forSupportedEfforts supportedEfforts: [String]?) -> ReasoningEffortOption? {
        let options = options(forSupportedEfforts: supportedEfforts)
        return options.count == 1 ? options[0] : nil
    }

    static func showsEffortControl(
        supportsReasoningEffort: Bool?,
        supportedEfforts: [String]?
    ) -> Bool {
        if let supportsReasoningEffort { return supportsReasoningEffort }
        if let supportedEfforts { return !supportedEfforts.isEmpty }
        return true
    }
}
