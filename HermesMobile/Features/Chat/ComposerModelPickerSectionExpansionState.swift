import Foundation

struct ComposerModelPickerSectionExpansionState {
    private var expandedGroupIDs: Set<String> = []
    private var collapsedSearchGroupIDs: Set<String> = []
    private var searchQuery = ""

    mutating func updateSearchText(_ searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }

        searchQuery = query
        collapsedSearchGroupIDs.removeAll()
    }

    func isExpanded(groupID: String) -> Bool {
        if searchQuery.isEmpty {
            return expandedGroupIDs.contains(groupID)
        }

        return !collapsedSearchGroupIDs.contains(groupID)
    }

    mutating func setExpanded(_ isExpanded: Bool, groupID: String) {
        if searchQuery.isEmpty {
            if isExpanded {
                expandedGroupIDs.insert(groupID)
            } else {
                expandedGroupIDs.remove(groupID)
            }
        } else if isExpanded {
            collapsedSearchGroupIDs.remove(groupID)
        } else {
            collapsedSearchGroupIDs.insert(groupID)
        }
    }
}

/// Tracks the provider groups whose server-supplied overflow models the user
/// has chosen to reveal. Both model pickers use the same small state model so
/// their counts and visible rows cannot drift apart.
struct ModelPickerOverflowExpansionState {
    private var expandedGroupIDs: Set<String> = []

    func isExpanded(groupID: String) -> Bool {
        expandedGroupIDs.contains(groupID)
    }

    func displayedModels(in group: ModelCatalogGroup) -> [ModelCatalogOption] {
        isExpanded(groupID: group.id) ? group.allModels : group.models
    }

    mutating func setExpanded(_ isExpanded: Bool, groupID: String) {
        if isExpanded {
            expandedGroupIDs.insert(groupID)
        } else {
            expandedGroupIDs.remove(groupID)
        }
    }
}
