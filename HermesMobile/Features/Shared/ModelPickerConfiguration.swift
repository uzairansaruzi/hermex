import SwiftUI

struct ModelPickerConfiguration {
    let navigationTitle: LocalizedStringKey
    let dismissTitle: LocalizedStringKey
    let dismissPlacement: ToolbarItemPlacement
    let customActionTitle: LocalizedStringKey
    let requiresCustomProviderID: Bool
    let showsCustomFavoriteStar: Bool
    let showsModelFavoriteStars: Bool
    let showsCurrentCustomModelGroup: Bool
    let showsSavedCustomModelGroup: Bool
    let dismissesOnCommit: Bool
    var searchPrompt: LocalizedStringKey = "Search models"

    static let composer = ModelPickerConfiguration(
        navigationTitle: "All models",
        dismissTitle: "Done",
        dismissPlacement: .topBarTrailing,
        customActionTitle: "Use Custom",
        requiresCustomProviderID: true,
        showsCustomFavoriteStar: true,
        showsModelFavoriteStars: true,
        showsCurrentCustomModelGroup: true,
        showsSavedCustomModelGroup: true,
        dismissesOnCommit: true,
        searchPrompt: "Search all models"
    )

    static let serverDefault = ModelPickerConfiguration(
        navigationTitle: "Default Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Save Custom Model",
        requiresCustomProviderID: false,
        showsCustomFavoriteStar: false,
        showsModelFavoriteStars: true,
        showsCurrentCustomModelGroup: false,
        showsSavedCustomModelGroup: false,
        dismissesOnCommit: false
    )

    static let hermesProfileDefault = ModelPickerConfiguration(
        navigationTitle: "Default Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Save Custom Model",
        requiresCustomProviderID: true,
        showsCustomFavoriteStar: false,
        showsModelFavoriteStars: false,
        showsCurrentCustomModelGroup: true,
        showsSavedCustomModelGroup: false,
        dismissesOnCommit: false
    )

    static let cronJob = ModelPickerConfiguration(
        navigationTitle: "Task Model",
        dismissTitle: "Cancel",
        dismissPlacement: .cancellationAction,
        customActionTitle: "Use Custom",
        requiresCustomProviderID: true,
        showsCustomFavoriteStar: false,
        showsModelFavoriteStars: false,
        showsCurrentCustomModelGroup: true,
        showsSavedCustomModelGroup: false,
        dismissesOnCommit: true
    )
}

struct ModelPickerClearAction {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
}

enum ModelPickerLoadStatus: Equatable {
    case loaded
    case loading
    case failed(String)
}
