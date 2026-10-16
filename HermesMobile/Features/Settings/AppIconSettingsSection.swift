import SwiftUI
import UIKit

struct AppIconSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedAppIcon = AppIconChoice.system
    @State private var updatingAppIcon: AppIconChoice?
    @State private var appIconErrorMessage: String?
    @State private var isAppIconPickerExpanded = false

    var body: some View {
        #if targetEnvironment(macCatalyst)
        EmptyView()
        #else
        if UIApplication.shared.supportsAlternateIcons {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(isExpanded: $isAppIconPickerExpanded) {
                    appIconChoices
                        .padding(.top, 12)
                } label: {
                    AppIconDisclosureLabel(selectedAppIcon: selectedAppIcon)
                }
                .tint(.secondary)

                if let appIconErrorMessage {
                    Text(appIconErrorMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                refreshSelectedAppIcon()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                refreshSelectedAppIcon()
            }
        }
        #endif
    }

    private var appIconChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(AppIconChoice.allCases.enumerated()), id: \.element.id) { index, icon in
                if index > 0 {
                    appIconDivider
                }

                HapticButton(feedbackStyle: .light) {
                    updateAppIcon(to: icon)
                } label: {
                    AppIconChoiceRow(
                        icon: icon,
                        isSelected: selectedAppIcon == icon,
                        isUpdating: updatingAppIcon == icon
                    )
                }
                .buttonStyle(.plain)
                .disabled(updatingAppIcon != nil)
            }
        }
    }

    private var appIconDivider: some View {
        Divider()
            .padding(.leading, 2)
            .opacity(0.72)
    }

    private func refreshSelectedAppIcon() {
        selectedAppIcon = AppIconChoice.current
    }

    private func updateAppIcon(to appIcon: AppIconChoice) {
        guard selectedAppIcon != appIcon, updatingAppIcon == nil else {
            return
        }

        appIconErrorMessage = nil
        updatingAppIcon = appIcon

        UIApplication.shared.setAlternateIconName(appIcon.alternateIconName) { error in
            Task { @MainActor in
                withAnimation {
                    updatingAppIcon = nil

                    if let error {
                        appIconErrorMessage = error.localizedDescription
                        selectedAppIcon = AppIconChoice.current
                        isAppIconPickerExpanded = true
                    } else {
                        selectedAppIcon = appIcon
                        isAppIconPickerExpanded = false
                    }
                }
            }
        }
    }
}

private struct AppIconDisclosureLabel: View {
    let selectedAppIcon: AppIconChoice

    var body: some View {
        HStack(spacing: 12) {
            AppIconChoicePreview(icon: selectedAppIcon)

            VStack(alignment: .leading, spacing: 2) {
                Text("App Icon")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(selectedAppIcon.title)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AppIconChoiceRow: View {
    let icon: AppIconChoice
    let isSelected: Bool
    let isUpdating: Bool

    var body: some View {
        HStack(spacing: 12) {
            AppIconChoicePreview(icon: icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(icon.title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(icon.subtitle)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating app icon")
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        "\(icon.title). \(icon.subtitle)"
    }
}

private struct AppIconChoicePreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: AppIconChoice

    @ViewBuilder
    var body: some View {
        switch icon {
        case .system:
            AppIconPreviewImage(
                name: colorScheme == .dark ? "AppIconDarkPreview" : "AppIconLightPreview",
                size: 44
            )
        case .light, .dark, .disco, .monochromeLight, .monochromeDark, .gradientLight, .gradientDark:
            if let previewImageName = icon.previewImageName {
                AppIconPreviewImage(name: previewImageName, size: 44)
            }
        }
    }
}

private struct AppIconPreviewImage: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
            .accessibilityHidden(true)
    }
}
