import SwiftUI

/// Settings > Appearance > Thinking Slider: every look running side by side, at a level the user can
/// change so they can compare how each one builds. Applies on this iPhone to every server.
struct ThinkingSliderPickerView: View {
    @AppStorage(ThinkingSliderLook.storageKey) private var selectedLook = ThinkingSliderLook.defaultLook
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var previewLevel = PreviewLevel.high

    private enum PreviewLevel: Double, CaseIterable, Identifiable {
        case low = 0.14, high = 0.57, ultra = 1

        var id: Self { self }

        var title: String {
            switch self {
            case .low: String(localized: "Min")
            case .high: ReasoningEffortOption.title(for: "high")
            case .ultra: ReasoningEffortOption.title(for: "ultra")
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Preview", selection: $previewLevel) {
                    ForEach(PreviewLevel.allCases) { level in
                        Text(verbatim: level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("How the Thinking control looks in Model settings.")
            }

            Section {
                ForEach(ThinkingSliderLook.allCases) { look in
                    row(look)
                }
            }
        }
        .settingsPage(String(localized: "Thinking Slider"))
    }

    private func row(_ look: ThinkingSliderLook) -> some View {
        Button {
            guard selectedLook != look else { return }
            selectedLook = look
            ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: look.name).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if selectedLook == look {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                ThinkingSliderTrack(look: look, level: previewLevel.rawValue, followsFinger: false)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedLook == look ? .isSelected : [])
    }
}
