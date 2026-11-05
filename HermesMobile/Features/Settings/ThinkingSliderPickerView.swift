import SwiftUI

/// Settings > Appearance > Thinking Slider: every look running side by side. Each slider can be
/// tapped and dragged like the real one, which sends nothing to any host, and the buttons above set
/// them all to one level to compare. Applies on this iPhone to every server.
struct ThinkingSliderPickerView: View {
    @AppStorage(ThinkingSliderLook.storageKey) private var selectedLook = ThinkingSliderLook.defaultLook
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var sharedLevel = SharedLevel.high
    /// Levels the user has dragged a look to since last setting them all.
    @State private var triedLevels: [ThinkingSliderLook: String] = [:]

    private enum SharedLevel: String, CaseIterable, Identifiable {
        case minimal, high, ultra

        var id: Self { self }
    }

    var body: some View {
        AppList {
            Section {
                // Buttons, not a segmented picker: pressing the current level has to put back any
                // slider that has been dragged away from it.
                HStack(spacing: 8) {
                    ForEach(SharedLevel.allCases) { level in
                        Button {
                            sharedLevel = level
                            triedLevels = [:]
                        } label: {
                            Text(verbatim: ReasoningEffortOption.shortTitle(for: level.rawValue))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(level == sharedLevel ? Color(.appText) : Color(.appTextSecondary))
                        .accessibilityAddTraits(level == sharedLevel ? .isSelected : [])
                    }
                }
            } appFooter: {
                Text("How the Thinking control looks in Model settings.")
            }

            Section {
                ForEach(ThinkingSliderLook.allCases) { look in
                    ThinkingSliderPickerRow(
                        look: look,
                        level: triedLevels[look] ?? sharedLevel.rawValue,
                        isSelected: selectedLook == look,
                        onTry: { triedLevels[look] = $0 },
                        onSelect: {
                            guard selectedLook != look else { return }
                            selectedLook = look
                            ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                        }
                    )
                }
            }
        }
        .settingsPage(String(localized: "Thinking Slider"))
    }
}

/// The name line selects the look, and the slider below it is only for trying.
private struct ThinkingSliderPickerRow: View {
    let look: ThinkingSliderLook
    let level: String
    let isSelected: Bool
    let onTry: (String) -> Void
    let onSelect: () -> Void

    @State private var drag = ThinkingSliderDrag()

    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: HermesModelCatalog.effortLevels, current: level)
    }

    private var shownLevel: String {
        drag.position.map { ladder.levels[ladder.index(atPosition: $0)] } ?? level
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Text(verbatim: look.name).foregroundStyle(.appPrimary)
                    Spacer(minLength: 8)
                    Text(verbatim: ReasoningEffortOption.title(for: shownLevel))
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                        .accessibilityHidden(true)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color(.appText) : Color(.appTextSecondary))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            ThinkingInteractiveTrack(look: look, ladder: ladder, drag: $drag) { index in
                onTry(ladder.levels[index])
            }
        }
    }
}
