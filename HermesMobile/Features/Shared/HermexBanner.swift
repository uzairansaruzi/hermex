import SwiftUI

/// A persistent in-flow status notice: an optional icon, an independently optional title/
/// description, and an optional action, either inset or full-width. Distinct from a Tag (a compact
/// display-only label) and from Card (a grouped content container) — a Banner always communicates
/// status about the surface it sits in. Title and description are caller-optional content regions,
/// not an interactive collapse/disclosure state: a caller that only has one line of copy simply omits
/// the other, rather than toggling anything at runtime.
struct HermexBanner: View {
    enum Semantic: Equatable {
        case information
        case warning
        case error
        case success
        case offline

        var tint: Color {
            switch self {
            case .information:
                .blue
            case .warning:
                .yellow
            case .error:
                .red
            case .success:
                .green
            case .offline:
                .orange
            }
        }

        /// Contrast-validated semantic foreground for all Banner content. Light appearance uses a
        /// darker step from the status family; dark appearance uses a lighter step from that same
        /// family. Every pair clears WCAG AA against any 12%-tinted fill over a light or dark base.
        var foreground: Color {
            switch self {
            case .information:
                HermesColorRamp.Neutral.adaptive(light: HermesColorRamp.Blue.s800, dark: HermesColorRamp.Blue.s300)
            case .warning:
                HermesColorRamp.Neutral.adaptive(light: HermesColorRamp.Gold.s950, dark: HermesColorRamp.Gold.s300)
            case .error:
                HermesColorRamp.Neutral.adaptive(light: HermesColorRamp.Red.s800, dark: HermesColorRamp.Red.s300)
            case .success:
                HermesColorRamp.Neutral.adaptive(light: HermesColorRamp.Green.s900, dark: HermesColorRamp.Green.s300)
            case .offline:
                HermesColorRamp.Neutral.adaptive(light: HermesColorRamp.Orange.s900, dark: HermesColorRamp.Orange.s300)
            }
        }

        var defaultIcon: String {
            switch self {
            case .information:
                "info.circle"
            case .warning:
                "exclamationmark.triangle"
            case .error:
                "xmark.octagon"
            case .success:
                "checkmark.circle"
            case .offline:
                "wifi.slash"
            }
        }
    }

    enum Presentation: Equatable {
        /// Full-width: horizontal padding is the caller's default page/section inset.
        case fullWidth(horizontalPadding: CGFloat = HermesSpacing.s16)
        /// Inset: the banner is its own rounded surface, for placement inside padded content.
        case inset
    }

    let semantic: Semantic
    let title: Text?
    let description: Text?
    var icon: String?
    var isIconDecorative = true
    var presentation: Presentation = .fullWidth()
    var action: Action?

    struct Action {
        var title: String?
        var icon: String?
        var accessibilityLabel: String?
        let handler: () -> Void

        /// A text-button-style action, e.g. "Update".
        init(title: String, handler: @escaping () -> Void) {
            self.title = title
            self.icon = nil
            self.accessibilityLabel = nil
            self.handler = handler
        }

        /// An icon-only action, e.g. the attachment error's dismiss control.
        init(icon: String, accessibilityLabel: String, handler: @escaping () -> Void) {
            self.title = nil
            self.icon = icon
            self.accessibilityLabel = accessibilityLabel
            self.handler = handler
        }
    }

    init(
        _ semantic: Semantic,
        title: Text? = nil,
        description: Text? = nil,
        icon: String? = nil,
        showsIcon: Bool = true,
        isIconDecorative: Bool = true,
        presentation: Presentation = .fullWidth(),
        action: Action? = nil
    ) {
        precondition(title != nil || description != nil, "HermexBanner requires a title, a description, or both")
        self.semantic = semantic
        self.title = title
        self.description = description
        self.icon = showsIcon ? (icon ?? semantic.defaultIcon) : nil
        self.isIconDecorative = isIconDecorative
        self.presentation = presentation
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: HermesSpacing.s8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: HermesIconSize.small))
                    .foregroundStyle(semantic.foreground)
                    .accessibilityHidden(isIconDecorative)
            }

            VStack(alignment: .leading, spacing: HermesSpacing.s2) {
                if let title {
                    title
                        .appFont(.subheadlineSemibold)
                        .foregroundStyle(semantic.foreground)
                }
                if let description {
                    description
                        .appFont(title == nil ? .subheadlineSemibold : .footnote)
                        .foregroundStyle(semantic.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                actionView(action)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, HermesSpacing.s12)
        .background(background)
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }

    @ViewBuilder
    private func actionView(_ action: Action) -> some View {
        Button(action: action.handler) {
            if let title = action.title {
                Text(title)
                    .appFont(.subheadlineSemibold)
                    .foregroundStyle(semantic.foreground)
            } else if let icon = action.icon {
                Image(systemName: icon)
                    .font(.system(size: HermesIconSize.small))
                    .foregroundStyle(semantic.foreground)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityLabel ?? action.title ?? "")
    }

    private var horizontalPadding: CGFloat {
        switch presentation {
        case .fullWidth(let horizontalPadding):
            horizontalPadding
        case .inset:
            HermesSpacing.s16
        }
    }

    @ViewBuilder
    private var background: some View {
        switch presentation {
        case .fullWidth:
            semantic.tint.opacity(0.12)
        case .inset:
            RoundedRectangle(cornerRadius: HermesRadius.card, style: .continuous)
                .fill(semantic.tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: HermesRadius.card, style: .continuous)
                        .stroke(semantic.tint.opacity(0.28), lineWidth: 0.5)
                )
        }
    }
}

extension HermexBanner {
    /// The Session-list and Chat offline-cache notice, unified: both read "Offline — viewing cached
    /// version" over an orange full-width banner with a wifi-slash glyph.
    static func offlineCache(horizontalPadding: CGFloat = HermesSpacing.s16) -> HermexBanner {
        HermexBanner(
            .offline,
            title: Text("Offline — viewing cached version"),
            presentation: .fullWidth(horizontalPadding: horizontalPadding)
        )
    }
}
