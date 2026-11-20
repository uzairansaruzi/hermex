import Foundation

@MainActor final class ReviewProgressStore {
    struct FileProgress: Equatable {
        var isCollapsed: Bool?
        var viewedPatch: Int?
    }

    private var scopes: [String: [String: FileProgress]] = [:]

    func files(in scope: String) -> [String: FileProgress] {
        scopes[scope] ?? [:]
    }

    func update(_ fileID: String, in scope: String, _ change: (inout FileProgress) -> Void) {
        change(&scopes[scope, default: [:]][fileID, default: FileProgress()])
    }

    func prune(to status: GitStatus?, in scope: String) {
        guard let status, status.isGit == true, status.truncated == false, let files = status.files else { return }
        prune(toListed: files, in: scope)
    }

    func prune(toListed files: [GitFile], in scope: String) {
        let listed = Set(files.map(\.id))
        scopes[scope] = scopes[scope]?.filter { listed.contains($0.key) }
    }
}

@MainActor struct ReviewDiffProgress {
    private(set) var collapsedFileIDs: Set<String> = []
    private(set) var viewedFileIDs: Set<String> = []
    private var defaults: ReviewDiffDefaultCollapse
    private var patches: [String: Int] = [:]
    private let store: ReviewProgressStore
    private let scope: String?

    init(files: [GitFile], initialFile: GitFile?, store: ReviewProgressStore, scope: String?) {
        self.store = store
        self.scope = scope
        defaults = ReviewDiffDefaultCollapse(files: files, initialFile: initialFile)
        guard let scope else { return }
        let stored = store.files(in: scope)
        for file in files {
            guard let isCollapsed = stored[file.id]?.isCollapsed else { continue }
            defaults.settle(file.id)
            if isCollapsed, file.id != initialFile?.id { collapsedFileIDs.insert(file.id) }
        }
    }

    nonisolated static func patch(for file: GitFile, state: ReviewDiffFileState) -> Int? {
        guard case .loaded(let diff) = state, diff.binary != true, diff.tooLarge != true, let text = diff.diff else { return nil }
        var hasher = Hasher()
        hasher.combine(file.id)
        hasher.combine(diff.kind ?? file.preferredDiffKind)
        hasher.combine(text)
        return hasher.finalize()
    }

    mutating func toggleFile(_ fileID: String) {
        defaults.settle(fileID)
        let isCollapsed = collapsedFileIDs.remove(fileID) == nil
        if isCollapsed { collapsedFileIDs.insert(fileID) }
        guard let scope else { return }
        store.update(fileID, in: scope) { $0.isCollapsed = isCollapsed }
    }

    mutating func reveal(_ fileID: String) {
        defaults.settle(fileID)
        collapsedFileIDs.remove(fileID)
        guard let scope else { return }
        store.update(fileID, in: scope) { $0.isCollapsed = false }
    }

    mutating func toggleViewed(_ fileID: String) {
        defaults.settle(fileID)
        let isViewed = viewedFileIDs.remove(fileID) == nil
        if isViewed {
            viewedFileIDs.insert(fileID)
            collapsedFileIDs.insert(fileID)
        }
        guard let scope else { return }
        let patch = isViewed ? patches[fileID] : nil
        let isCollapsed = collapsedFileIDs.contains(fileID)
        store.update(fileID, in: scope) {
            $0.viewedPatch = patch
            $0.isCollapsed = isCollapsed
        }
    }

    mutating func apply(_ rows: [ReviewDiffRow], patches: [String: Int]) {
        if let scope {
            for (fileID, stored) in store.files(in: scope) {
                guard let viewedPatch = stored.viewedPatch else { continue }
                guard let patch = patches[fileID] else {
                    viewedFileIDs.remove(fileID)
                    continue
                }
                if viewedPatch == patch {
                    viewedFileIDs.insert(fileID)
                    continue
                }
                viewedFileIDs.remove(fileID)
                collapsedFileIDs.remove(fileID)
                defaults.settle(fileID)
                store.update(fileID, in: scope) { $0 = ReviewProgressStore.FileProgress(isCollapsed: false, viewedPatch: nil) }
            }
        }
        self.patches = patches
        defaults.apply(rows, to: &collapsedFileIDs)
    }
}
