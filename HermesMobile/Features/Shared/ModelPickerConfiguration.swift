import SwiftUI

/// Everything that differs between the two surfaces that open
/// `ModelPickerSheet`: the composer, which switches the running session's model
/// instantly, and Settings > Default Model, which writes to the server and can
/// fail.
///
/// Call sites take a preset rather than assembling a pile of booleans.
struct ModelPickerConfiguration {
    let navigationTitle: LocalizedStringKey
    let dismissTitle: LocalizedStringKey
    let dismissPlacement: ToolbarItemPlacement
    /// Label on the custom entry's commit button.
    let customActionTitle: LocalizedStringKey
    /// Whether the custom entry needs a provider ID before it can commit, and
    /// whether the provider field is prefilled. The composer always names a
    /// provider; the server default accepts a bare model id, as it always has.
    let requiresCustomProviderID: Bool
    /// Whether the custom entry carries a favorites star. Off for the server
    /// default, where a custom model can never gain a `Saved Custom` group to
    /// be shown in.
    let showsCustomFavoriteStar: Bool
    /// Whether the `Current` / `Saved Custom` groups render above the catalog.
    let showsCustomModelGroups: Bool
    /// Whether committing a model closes the sheet. The server default stays
    /// open until the server confirms the save.
    let dismissesOnCommit: Bool

    static let composer = ModelPickerConfiguration(
        navigationTitle: "Choose Model",
        dismissTitle: "Done",
        dismissPlacement: .topBarTrailing,
        customActionTitle: "Use Custom",
        requiresCustomProviderID: true,
        showsCustomFavoriteStar: true,
        showsCustomModelGroups: true,
        dismissesOnCommit: true
    )

    static let serverDefault = ModelPickerConfiguration(
        navigationTitle: "Default Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Save Custom Model",
        requiresCustomProviderID: false,
        showsCustomFavoriteStar: false,
        showsCustomModelGroups: false,
        dismissesOnCommit: false
    )
}

/// What the owner's catalog load is doing. The composer has its catalog before
/// the sheet opens and is always `.loaded`; Settings loads inside the sheet and
/// needs somewhere to show progress and failure.
enum ModelPickerLoadStatus: Equatable {
    case loaded
    case loading
    case failed(String)
}
