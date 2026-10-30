import Foundation

/// A chat's review progress (#1384): the files the user folded or opened and the patches they
/// marked viewed, per repository (`GitDataClient.reviewScope`), so the Changes sheet and a turn's
/// diff reopen where the user left them. `ChatView` owns one in memory: closing the chat or
/// switching servers drops it, and nothing here is persisted or logged.
///
/// A turn's diff shows only some of the changes, so a file is forgotten only when a complete
/// status read no longer lists it (`prune(to:in:)`).
@MainActor final class ReviewProgressStore {
    struct FileProgress: Equatable {
        /// The user's own fold (true) or unfold (false); nil leaves the file to its default.
        var isCollapsed: Bool?
        /// The patch the user marked viewed (`ReviewDiffProgress.patch(for:state:)`); nil when
        /// unviewed, or marked before a patch had loaded.
        var viewedPatch: Int?
    }

    private var scopes: [String: [String: FileProgress]] = [:]

    func files(in scope: String) -> [String: FileProgress] {
        scopes[scope] ?? [:]
    }

    func update(_ fileID: String, in scope: String, _ change: (inout FileProgress) -> Void) {
        change(&scopes[scope, default: [:]][fileID, default: FileProgress()])
    }

    /// Forgets the files a successful, complete status read no longer lists. A failed read, a
    /// capped or unknown list, or a folder outside a repository proves nothing.
    func prune(to status: GitStatus?, in scope: String) {
        guard let status, status.isGit == true, status.truncated == false, let files = status.files else { return }
        prune(toListed: files, in: scope)
    }

    /// Forgets the files a whole list of `scope`'s changes no longer names, as a branch's
    /// `review/list` is (#1386).
    func prune(toListed files: [GitFile], in scope: String) {
        let listed = Set(files.map(\.id))
        scopes[scope] = scopes[scope]?.filter { listed.contains($0.key) }
    }
}

/// One open review's folds and viewed marks: `GitDiffView`'s render state, written through to the
/// chat's `ReviewProgressStore`. It opens with the stored choices, except that the file the user
/// tapped reads open without changing what is stored, and a stored viewed mark shows only while its
/// file's patch in the current load matches, so a refresh hides it until the patch loads again; a
/// different patch clears the mark and opens the file. Marking a
/// file viewed folds it; un-viewing leaves it folded (#399). Files the user hasn't chosen for take
/// `ReviewDiffDefaultCollapse`.
@MainActor struct ReviewDiffProgress {
    private(set) var collapsedFileIDs: Set<String> = []
    private(set) var viewedFileIDs: Set<String> = []
    private var defaults: ReviewDiffDefaultCollapse
    /// The latest publish's patch per file; a file still loading, failed, binary or too large has none.
    private var patches: [String: Int] = [:]
    private let store: ReviewProgressStore
    /// Nil for a webui session without an ID, whose progress lives only as long as the review.
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

    /// What a viewed mark vouches for: a loaded text patch with its path and kind. `Hasher` is
    /// seeded per launch, which suits memory that dies with the chat. The loader computes it off
    /// the main actor, next to the file's rows.
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

    mutating func toggleViewed(_ fileID: String) {
        defaults.settle(fileID)
        let isViewed = viewedFileIDs.remove(fileID) == nil
        if isViewed {
            viewedFileIDs.insert(fileID)
            collapsedFileIDs.insert(fileID)
        }
        guard let scope else { return }
        // A mark made before the patch loaded vouches for nothing, so only this review shows it.
        let patch = isViewed ? patches[fileID] : nil
        let isCollapsed = collapsedFileIDs.contains(fileID)
        store.update(fileID, in: scope) {
            $0.viewedPatch = patch
            $0.isCollapsed = isCollapsed
        }
    }

    /// Takes the loader's latest full row list and the patches loaded so far, checking each stored
    /// viewed mark against them before the defaults fold anything. A file without a patch yet
    /// (loading, failed, binary or too large) hides its mark and keeps it stored.
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
