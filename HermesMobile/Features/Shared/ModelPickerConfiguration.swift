import SwiftUI

/// Everything that differs between the surfaces that open `ModelPickerSheet`:
/// the composer, which switches the running session's model instantly,
/// Settings > Default Model, which writes to the server and can fail, and the
/// Task editor, which only edits a local draft.
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
    /// Whether a `Current Custom` group renders above the catalog when the
    /// current selection has no row of its own. Surfaces that must always be
    /// able to answer "which one am I on" keep it, so a model the catalog
    /// stopped offering never reads as unconfigured.
    let showsCurrentCustomModelGroup: Bool
    /// Whether the favorites- and recents-backed `Saved Custom` group renders
    /// above the catalog. Off wherever the picker must not touch or reflect
    /// `ModelFavoritesStore`.
    let showsSavedCustomModelGroup: Bool
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
        showsCurrentCustomModelGroup: true,
        showsSavedCustomModelGroup: true,
        dismissesOnCommit: true
    )

    static let serverDefault = ModelPickerConfiguration(
        navigationTitle: "Default Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Save Custom Model",
        requiresCustomProviderID: false,
        showsCustomFavoriteStar: false,
        showsCurrentCustomModelGroup: false,
        showsSavedCustomModelGroup: false,
        dismissesOnCommit: false
    )

    /// The Task editor's model picker. It edits a draft, so committing is
    /// instant and closes the sheet.
    ///
    /// Nothing here reads or writes `ModelFavoritesStore`: starring a model
    /// while editing a scheduled task would silently change what the chat
    /// composer offers, and the favorites-backed `Saved Custom` group would
    /// list models this task was never configured with. The `Current Custom`
    /// group stays, because a task configured last month against a model the
    /// catalog has since dropped must still show which model that was.
    static let cronJob = ModelPickerConfiguration(
        navigationTitle: "Task Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Use Custom",
        requiresCustomProviderID: true,
        showsCustomFavoriteStar: false,
        showsCurrentCustomModelGroup: true,
        showsSavedCustomModelGroup: false,
        dismissesOnCommit: true
    )
}

/// The "no model" row a surface can put above the catalog, for the surfaces
/// where an unset model is a real value the server acts on rather than an
/// unfinished form. A way in needs a way out.
struct ModelPickerClearAction {
    let title: LocalizedStringKey
    /// Whether the row carries the selection right now, i.e. nothing is set.
    let isSelected: Bool
    let action: () -> Void
}

/// What the owner's catalog load is doing. The composer has its catalog before
/// the sheet opens and is always `.loaded`; Settings loads inside the sheet and
/// needs somewhere to show progress and failure.
enum ModelPickerLoadStatus: Equatable {
    case loaded
    case loading
    case failed(String)
}
