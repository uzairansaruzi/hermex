import Foundation

/// A Hermes chat's repository (#1114), read through the host's Git routes on the sign-in its Bot
/// screens share, mapped into webui's Git models so the menu, Changes sheet, diffs and
/// turn-changes card read it unchanged. It shows the whole repository holding the chat's folder,
/// not only the folder: the root is resolved once from `GET /api/fs/git-root` and every read names
/// it, since the host's paths are relative to the root. A folder outside a repository is asked
/// again on the next read, so a repository the agent creates shows at turn end.
///
/// Writes (#1115) go through the host's review routes, which guard nothing: a file-less stage or
/// revert covers the whole tree, `file` is a git pathspec, a commit with nothing staged stages
/// everything first, and a push on a detached HEAD does nothing. So every write names one exact
/// file (`HermesREST.isGitFile`), reads the rows it acts on again, and the guards live here,
/// ahead of the request (`HermesGitRefusal`); each request also asks the owning chat first
/// (`WriteOwner`). Each successful write answers the status read again.
///
/// Neither the root nor git's own output (a refusal's `detail`, which can name host paths) reaches
/// the screen or a log. Checked at the `HERMES_AGENT_TESTED_SHA` pin (ca678285) in
/// `hermes_cli/web_git.py` and `web_routers/git.py`.
@MainActor final class HermesGitClient: GitDataClient {
    /// Writes a commit message for a diff with the host's one-shot model call
    /// (`HermesChatTurnCoordinator.commitMessage`): the diff, the recent subjects to match, and on
    /// Regenerate the last suggestion, which the host is told not to repeat.
    typealias MessageWriter = @MainActor @Sendable (_ diff: String, _ recent: String, _ avoid: String?) async throws -> String
    /// A check that throws once a write may no longer go out.
    typealias Dispatch = @MainActor @Sendable () throws -> Void
    /// The chat that owns the repository (`HermesChatTurnCoordinator.gitWriteDispatch`): asked as
    /// each write begins, it throws while a turn runs or the chat shows cached data, else returns
    /// the check every request of the write runs as it goes out, which also throws once the chat
    /// reattached or left this folder. So a write stops partway rather than run under a turn.
    typealias WriteOwner = @MainActor @Sendable () throws -> Dispatch

    let context: HermesWorkspaceContext
    private let http: HermesConnection
    private let writeMessage: MessageWriter?
    private let writeOwner: WriteOwner?
    /// Shared by everything that writes through this client: the chat's Git menu and commit sheet.
    let writeLock: GitWriteLock?
    /// The repository root, once `fs/git-root` has found one. Never shown, logged or persisted.
    private var root: String?

    /// webui's diff cap: a longer diff shows "Diff too large to show." instead of its text.
    static let maximumDiffBytes = 512 * 1024
    /// The longest diff the host's `commit_message` template reads; past it a message may be partial.
    static let messageDiffCharacters = 12_000
    /// The most of the selected files' diffs sent for a message, as `commit-context` caps its own.
    static let selectedDiffCharacters = 120_000

    init(context: HermesWorkspaceContext, http: HermesConnection, writeMessage: MessageWriter? = nil,
         writeOwner: WriteOwner? = nil) {
        self.context = context
        self.http = http
        self.writeMessage = writeMessage
        self.writeOwner = writeOwner
        self.writeLock = GitWriteLock()
    }

    /// A Hermes host's writes answer only `{ok}`: a failed one reads the status again, and a
    /// commit shows its sha.
    nonisolated var isHermes: Bool { true }

    /// The branch, ahead/behind and dirty counts from `git/status`; nil outside a repository.
    func info() async throws -> GitInfo? {
        guard let root = try await repositoryRoot() else { return nil }
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary.fields != nil else { return nil }
        let changed = summary["changed"].integer ?? 0
        let untracked = summary["untracked"].integer ?? 0
        return GitInfo(branch: Self.branch(summary), dirty: changed, modified: changed - untracked, untracked: untracked,
                       ahead: summary["ahead"].integer, behind: summary["behind"].integer, isGit: true)
    }

    /// Every uncommitted change: `review/list`'s rows joined by path with `git/status`' flags
    /// (`Self.status(summary:changes:)`). `isGit == false` outside a repository.
    func status() async throws -> GitStatus? {
        guard let root = try await repositoryRoot() else { return Self.notARepository }
        return try await currentStatus(root)
    }

    /// `status()` of the repository at `root`.
    private func currentStatus(_ root: String) async throws -> GitStatus {
        async let summary = send(.gitStatus(repository: root))
        async let changes = send(.gitChanges(repository: root))
        let (summaryBody, changesBody) = try await (summary, changes)
        return Self.status(summary: try Self.json(summaryBody), changes: try Self.json(changesBody))
    }

    /// The row's staged diff when it has only staged changes, else its worktree diff, which the
    /// host synthesizes as all-add for an untracked file. A staged row past the status cap may also
    /// have worktree edits, so it reads its whole change against HEAD; before the first commit
    /// there is no HEAD and that read is empty, so a new file reads as its current content
    /// (`currentContent(of:root:)`). Over `maximumDiffBytes` it is too large.
    func diff(for file: GitFile) async throws -> GitDiff? {
        guard let root = try await repositoryRoot() else { return nil }
        let path = file.displayPath
        let wholeChange = file.staged == true && file.unstaged == nil
        let kind = wholeChange ? nil : file.preferredDiffKind
        let request: HermesREST = wholeChange ? .gitFileDiff(repository: root, file: path)
            : .gitDiff(repository: root, file: path, staged: kind == "staged")
        let text = try Self.json(try await send(request))["diff"].text ?? ""
        if wholeChange, text.isEmpty, file.changeKind == .added {
            return try await currentContent(of: path, root: root)
        }
        let tooLarge = text.utf8.count > Self.maximumDiffBytes
        return GitDiff(path: path, kind: kind, binary: Self.isBinary(text),
                       tooLarge: tooLarge, additions: nil, deletions: nil, diff: tooLarge ? nil : text)
    }

    /// A new file's whole content as an all-add diff, from `fs/read-text` (its first 512 KiB,
    /// `truncated` past that, the same cap as `maximumDiffBytes`).
    private func currentContent(of path: String, root: String) async throws -> GitDiff {
        let file = try Self.json(try await send(.fsReadText(path: root + "/" + path)))
        let binary = file["binary"].flag == true
        let tooLarge = file["truncated"].flag == true
        var lines = (file["text"].text ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let diff = "diff --git a/\(path) b/\(path)\n--- /dev/null\n+++ b/\(path)\n"
            + (lines.isEmpty ? "" : "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+\($0)\n" }.joined())
        return GitDiff(path: path, kind: nil, binary: binary, tooLarge: tooLarge, additions: nil, deletions: nil,
                       diff: binary || tooLarge ? nil : diff)
    }

    /// A turn's tool path as its row's root-relative path: Hermes tools name files relative to the
    /// chat's folder or absolutely. Left as named until the root is known, or when it lies outside.
    func rowPath(forToolPath path: String) -> String {
        guard let root else { return path }
        return Self.rowPath(path, folder: context.cwd, root: root)
    }

    /// `rowPath(forToolPath:)` for a chat working in `folder` inside the repository at `root`.
    /// The path is anchored to the folder and its `.` and `..` collapsed, as the host resolves
    /// it. The host's root has its symlinks resolved and the folder may not, so a folder spelled
    /// through one (`/tmp/app/Sources` in `/private/tmp/app`) is matched by the root's trailing
    /// folders. Symlinks aren't followed: one that renames a folder leaves the path as named.
    nonisolated static func rowPath(_ path: String, folder: String, root: String) -> String {
        let target = components(path.hasPrefix("/") ? path : folder + "/" + path)
        let rootParts = components(root)
        let folderParts = components(folder)
        let folderSpelling = (0...min(rootParts.count, folderParts.count)).reversed().lazy
            .map { Array(folderParts.prefix($0)) }
            .first { !$0.isEmpty && rootParts.suffix($0.count).elementsEqual($0) }
        for base in [rootParts, folderSpelling].compactMap({ $0 }) where target.count > base.count && target.starts(with: base) {
            return target.dropFirst(base.count).joined(separator: "/")
        }
        return path
    }

    /// An absolute path's folder names, with `.` dropped and `..` taking off the one before it.
    private nonisolated static func components(_ path: String) -> [String] {
        path.split(separator: "/").reduce(into: []) { parts, part in
            switch part {
            case ".": break
            case "..": _ = parts.popLast()
            default: parts.append(String(part))
            }
        }
    }

    /// `git/status` and `review/list` as one `GitStatus`. Rows are `review/list`'s, which lists
    /// every change; `status.files` stops at 200 and adds the flags a row lacks. A row past it has
    /// no `unstaged` flag (unknown, not clean) and takes untracked and conflicted from its status
    /// letter (`?`, `U`).
    /// The list is whole, so it is never `truncated`; `changed` is the host's full count.
    nonisolated static func status(summary: BotJSON, changes: BotJSON) -> GitStatus {
        guard summary.fields != nil else { return notARepository }
        var flags: [String: BotJSON] = [:]
        for entry in summary["files"].list ?? [] {
            if let path = entry["path"].text { flags[path] = entry }
        }
        let files = (changes["files"].list ?? []).compactMap { row -> GitFile? in
            guard let path = row["path"].text, !path.isEmpty else { return nil }
            let flag = flags[path]
            let letter = row["status"].text
            return GitFile(path: path, status: letter, staged: row["staged"].flag ?? flag?["staged"].flag,
                           unstaged: flag?["unstaged"].flag, untracked: flag?["untracked"].flag ?? (letter == "?"),
                           conflict: flag?["conflicted"].flag ?? (letter == "U"),
                           additions: row["added"].integer, deletions: row["removed"].integer)
        }
        let totals = GitTotals(changed: summary["changed"].integer ?? files.count, staged: summary["staged"].integer,
                               unstaged: summary["unstaged"].integer, untracked: summary["untracked"].integer,
                               conflicts: summary["conflicted"].integer)
        return GitStatus(isGit: true, branch: branch(summary), upstream: nil, ahead: summary["ahead"].integer,
                         behind: summary["behind"].integer, totals: totals, files: files, truncated: false)
    }

    private nonisolated static let notARepository = GitStatus(isGit: false, branch: nil, upstream: nil, ahead: nil,
                                                              behind: nil, totals: nil, files: nil, truncated: nil)

    /// The branch's name, or `HEAD` when detached, as webui names it.
    private nonisolated static func branch(_ summary: BotJSON) -> String? {
        summary["branch"].text ?? (summary["detached"].flag == true ? "HEAD" : nil)
    }

    /// A diff with no hunk whose patch says the file is binary.
    private nonisolated static func isBinary(_ text: String) -> Bool {
        !text.contains("\n@@") && text.split(separator: "\n").contains { $0.hasPrefix("Binary files ") && $0.hasSuffix(" differ") }
    }

    // MARK: - Writes (#1115)

    /// Stages each file with something to stage, one request per file. A conflicted file is
    /// refused: staging it would mark it resolved.
    func stage(_ files: [GitFile]) async throws -> GitStatus? {
        try await writing(files) { root, rows, dispatch in
            guard !rows.contains(where: { $0.conflict == true }) else { throw HermesGitRefusal.conflictedStage }
            for row in rows where row.staged != true || row.unstaged != false {
                try await self.write(.gitStage(repository: root, file: row.path ?? ""), dispatch)
            }
        }
    }

    /// Unstages each staged file, one request per file. A rename is refused: the host's row names
    /// only its new path, so its old path's deletion would stay staged.
    func unstage(_ files: [GitFile]) async throws -> GitStatus? {
        try await writing(files) { root, rows, dispatch in
            guard !rows.contains(where: Self.isRename) else { throw HermesGitRefusal.renamedUnstage }
            for row in rows where row.staged == true {
                try await self.write(.gitUnstage(repository: root, file: row.path ?? ""), dispatch)
            }
        }
    }

    /// Returns each file to HEAD, one at a time. A staged one is unstaged first, so a file new in
    /// the index becomes untracked and goes too; the host deletes an untracked file. Without
    /// `deleteUntracked` (a confirmation that didn't say so) a file that would be deleted is left
    /// alone. A conflicted file is refused, as webui refuses it, and so is a rename: the host's
    /// row names only its new path, so its old one couldn't be put back.
    func discard(_ files: [GitFile], deleteUntracked: Bool) async throws -> GitStatus? {
        try await writing(files) { root, rows, dispatch in
            guard !rows.contains(where: { $0.conflict == true }) else { throw HermesGitRefusal.conflictedDiscard }
            guard !rows.contains(where: Self.isRename) else { throw HermesGitRefusal.renamedDiscard }
            for row in rows where deleteUntracked || !Self.isNew(row) {
                let path = row.path ?? ""
                if row.staged == true { try await self.write(.gitUnstage(repository: root, file: path), dispatch) }
                try await self.write(.gitRevert(repository: root, file: path), dispatch)
            }
        }
    }

    /// Commits what is staged, or only `files` (`commitSelected`). Refused while the repository
    /// has a conflict, and with nothing staged, which the host would answer by staging everything.
    func commit(message: String, only files: [GitFile]?) async throws -> GitCommitResponse {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        if let files { return try await commitSelected(files, message: message, root: root, dispatch: dispatch) }
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard (summary["conflicted"].integer ?? 0) == 0 else { throw HermesGitRefusal.conflictedCommit }
        guard (summary["staged"].integer ?? 0) > 0 else { throw HermesGitRefusal.nothingStaged }
        try await write(.gitCommit(repository: root, message: message), dispatch, deadline: .provisioning)
        return try await committed(root, paths: nil)
    }

    /// The host commits the whole index, so "commit selected" is a sequence: unstage everything,
    /// stage the selection, commit, then stage again the files that were staged before. `git add`
    /// puts back a whole file only, so the sequence is refused before it starts while a staged
    /// file also has worktree edits, or may have (a row past the status cap), or is a rename,
    /// whose old path the host's row doesn't name; while a staged file's path isn't one file to
    /// stage again (`rows(for:in:)`); and before the first commit, where the host can't unstage
    /// everything. A failure once any write went out, whose lost reply may hide that it ran,
    /// stages those files again and throws; one staging them again after the commit is reported
    /// with it (`stagingNotRestored`).
    private func commitSelected(_ files: [GitFile], message: String, root: String,
                                dispatch: @escaping Dispatch) async throws -> GitCommitResponse {
        let current = try await currentStatus(root)
        let rows = current.files ?? []
        guard (current.totals?.conflicts ?? 0) == 0, !rows.contains(where: { $0.conflict == true }) else {
            throw HermesGitRefusal.conflictedCommitSelected
        }
        let selected = try Self.rows(for: files, in: rows).compactMap(\.path)
        guard !selected.isEmpty else { throw HermesGitRefusal.nothingStaged }
        let staged = rows.filter { $0.staged == true }
        guard !staged.contains(where: { $0.unstaged != false || Self.isRename($0) }) else {
            throw HermesGitRefusal.partlyStagedSelection
        }
        let restaged = try Self.rows(for: staged, in: rows).compactMap(\.path)
        guard Self.text(try Self.json(try await send(.gitHead(repository: root)))["sha"]) != nil else {
            throw HermesGitRefusal.firstCommitSelected
        }
        let sentBefore = sentWrites
        do {
            try await write(.gitUnstage(repository: root, file: nil), dispatch)
            for path in selected { try await write(.gitStage(repository: root, file: path), dispatch) }
            // With nothing staged the host would stage everything instead.
            let summary = try Self.json(try await send(.gitStatus(repository: root)))
            guard (summary["staged"].integer ?? 0) > 0 else { throw HermesGitRefusal.nothingStaged }
            try await write(.gitCommit(repository: root, message: message), dispatch, deadline: .provisioning)
        } catch {
            guard sentWrites > sentBefore else { throw error }
            do {
                try await write(.gitUnstage(repository: root, file: nil), dispatch)
                for path in restaged { try await write(.gitStage(repository: root, file: path), dispatch) }
            } catch {
                throw HermesGitRefusal.restoreFailed
            }
            throw error
        }
        var restored = true
        for path in restaged where !selected.contains(path) {
            do { try await write(.gitStage(repository: root, file: path), dispatch) } catch { restored = false }
        }
        return try await committed(root, paths: selected, stagingRestored: restored)
    }

    /// The new commit's short sha and the status after it.
    private func committed(_ root: String, paths: [String]?, stagingRestored: Bool = true) async throws -> GitCommitResponse {
        let sha = (try? Self.json(try await send(.gitHead(repository: root)))).flatMap { Self.text($0["sha"]) }
        return GitCommitResponse(ok: true, commit: sha.map { String($0.prefix(7)) }, paths: paths,
                                 status: try? await status(), git: nil, stagingNotRestored: !stagingRestored)
    }

    /// Pushes the branch to its upstream, or to origin as its new upstream. A detached HEAD,
    /// which the host would skip without a word, is refused.
    func push() async throws -> GitRemoteActionResponse {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary["detached"].flag != true else { throw HermesGitRefusal.detachedHead }
        try await write(.gitPush(repository: root), dispatch, deadline: .provisioning)
        return GitRemoteActionResponse(ok: true, message: nil, status: try? await status())
    }

    /// A commit message from the host's model, as Desktop drafts one: `commit-context`'s diff of
    /// what would commit, or the selected files' whole changes, with its recent subjects to match.
    /// `avoiding` is the last suggestion, so Regenerate gives a different one. Before the first
    /// commit a selected new file's whole change is empty, so it is sent as its current content,
    /// as `diff(for:)` shows it.
    func suggestMessage(for files: [GitFile]?, avoiding previous: String?) async throws -> GitCommitMessageResponse {
        guard let writeMessage else { throw HermesGitRefusal.noMessage }
        let root = try await writableRoot()
        let context = try Self.json(try await send(.gitCommitContext(repository: root)))
        var diff = context["diff"].text ?? ""
        if let files {
            diff = ""
            for file in files where diff.count < Self.selectedDiffCharacters {
                let path = file.path ?? file.displayPath
                let change = try Self.json(try await send(.gitFileDiff(repository: root, file: path)))["diff"].text ?? ""
                diff += change.isEmpty && file.changeKind == .added
                    ? try await currentContent(of: path, root: root).diff ?? "" : change
            }
            diff = String(diff.prefix(Self.selectedDiffCharacters))
        }
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HermesGitRefusal.noMessage }
        let text: String
        do { text = try await writeMessage(diff, context["recent"].text ?? "", previous) } catch is CancellationError {
            throw CancellationError()
        } catch { throw HermesGitRefusal.noMessage }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw HermesGitRefusal.noMessage }
        return GitCommitMessageResponse(ok: true, message: message, truncated: diff.count > Self.messageDiffCharacters)
    }

    /// A file a revert deletes: untracked, or new in the index.
    private nonisolated static func isNew(_ file: GitFile) -> Bool {
        file.untracked == true || file.changeKind == .added
    }

    /// A staged rename or copy, whose row names only its new path.
    private nonisolated static func isRename(_ file: GitFile) -> Bool {
        ["R", "C"].contains((file.status ?? "").uppercased().first.map(String.init) ?? "")
    }

    /// A non-empty string, else nil.
    private nonisolated static func text(_ value: BotJSON) -> String? {
        value.text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Runs `writes` at the root on the rows the host lists now for `files`, then reads the status
    /// again. The sheet's rows can be stale, so the write reads them again and matches them by
    /// exact path (`rows(for:in:)`); a file with no change now is left out.
    private func writing(_ files: [GitFile],
                         _ writes: (String, [GitFile], @escaping Dispatch) async throws -> Void) async throws -> GitStatus? {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        let rows = try Self.rows(for: files, in: try await currentStatus(root).files ?? [])
        try await writes(root, rows, dispatch)
        return try? await status()
    }

    /// The current rows for `files`, by exact path, never trimmed. A path that isn't one file
    /// (`HermesREST.isGitFile`), which the host would read as the whole tree, is refused, and so
    /// is one the host lists twice: it trims a tracked file's name, so ` a` and `a` can share one.
    private nonisolated static func rows(for files: [GitFile], in current: [GitFile]) throws -> [GitFile] {
        try files.compactMap { file in
            guard let path = file.path, HermesREST.isGitFile(path) else { throw HermesGitRefusal.failed }
            let matches = current.filter { $0.path == path }
            guard matches.count < 2 else { throw HermesGitRefusal.failed }
            return matches.first
        }
    }

    /// The owner's check for one write, which each of its requests runs again as it goes out.
    private func beginWrite() throws -> Dispatch {
        guard let writeOwner else { return Self.unowned }
        return try writeOwner()
    }

    /// The check of a client no chat owns, as a test's: every write may go out.
    private static let unowned: Dispatch = {}

    /// The root for a write; a folder outside a repository has nothing to write.
    private func writableRoot() async throws -> String {
        guard let root = try await repositoryRoot() else { throw HermesGitUnavailable() }
        return root
    }

    /// One write, sent only while `dispatch` passes and counted in `sentWrites` as it goes out. A
    /// refusal reads as `HermesGitRefusal.failed`, never git's output.
    private func write(_ rest: HermesREST, _ dispatch: @escaping Dispatch,
                       deadline: HermesConnection.Deadline = .standard) async throws {
        _ = try await send(rest, deadline: deadline, refusal: HermesGitRefusal.failed) { [weak self] in
            try dispatch()
            self?.sentWrites += 1
        }
    }

    /// Writes that went out. A write whose reply is lost may still have run, so Commit Selected
    /// restores the index once any of its writes went out.
    private var sentWrites = 0

    /// The root of the repository holding the chat's folder, resolved once; nil outside one.
    private func repositoryRoot() async throws -> String? {
        if let root { return root }
        let found = try Self.json(try await send(.gitRoot(path: context.cwd)))["root"].text
        root = found.flatMap { $0.isEmpty ? nil : $0 }
        return root
    }

    /// One request's body. A refusal (400 `{detail}`, git's stderr) and any other failed status
    /// read as `refusal`, so neither git's output nor a host path reaches the screen. A dropped
    /// request reads as webui's network failure; the sign-in's own failures keep theirs.
    private func send(_ rest: HermesREST, deadline: HermesConnection.Deadline = .standard,
                      refusal: any Error = HermesGitUnavailable(),
                      validateDispatch: Dispatch? = nil) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest, deadline: deadline, validateDispatch: validateDispatch) } catch let error as URLError {
            throw APIError.network(underlying: error)
        }
        do { return try HermesCronClient.accepted(reply) } catch is HermesCronRefusal {
            throw refusal
        } catch let error as APIError {
            if case .http = error { throw refusal }
            throw error
        }
    }

    private nonisolated static func json(_ body: Data) throws -> BotJSON {
        do { return try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
    }
}

/// A Git read a Hermes host refused (#1114), shown with the existing copy instead of git's output.
struct HermesGitUnavailable: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "Repository status unavailable") }
}

/// A Git write `HermesGitClient` refuses before sending it, or one the host refused (#1115).
/// webui's wording where it has one.
enum HermesGitRefusal: LocalizedError, Equatable {
    case conflictedStage
    case conflictedDiscard
    case conflictedCommit
    case conflictedCommitSelected
    case nothingStaged
    case detachedHead
    case noMessage
    case renamedDiscard
    case renamedUnstage
    /// A staged file is partly staged, may be (past the status cap), or is a rename.
    case partlyStagedSelection
    case firstCommitSelected
    /// A turn is running in the chat that owns the repository.
    case turnRunning
    /// A Commit Selected that failed before its commit couldn't stage the files again either.
    case restoreFailed
    /// The host refused it, or it names no single file; git's own output isn't shown.
    case failed

    var errorDescription: String? {
        switch self {
        case .conflictedStage: String(localized: "Conflicted files cannot be staged from this panel")
        case .conflictedDiscard: String(localized: "Conflicted files cannot be discarded from this panel")
        case .conflictedCommit: String(localized: "Resolve conflicts before committing")
        case .conflictedCommitSelected: String(localized: "Resolve conflicts before committing selected files")
        case .nothingStaged: String(localized: "Stage changes before committing")
        case .detachedHead: String(localized: "Cannot push from a detached HEAD")
        case .noMessage: String(localized: "No commit message could be generated.")
        case .renamedDiscard: String(localized: "Renamed files cannot be discarded from this panel")
        case .renamedUnstage: String(localized: "Renamed files cannot be unstaged from this panel")
        case .partlyStagedSelection:
            String(localized: "Fully stage or fully unstage partly staged or renamed files before committing selected files")
        case .firstCommitSelected: String(localized: "Make the first commit with Commit, then commit selected files")
        case .turnRunning: String(localized: "Wait for the active response to finish before changing this repository.")
        case .restoreFailed: String(localized: "Git couldn’t finish this change, and the staged files couldn’t be restored.")
        case .failed: String(localized: "Git couldn’t finish this change on your Hermes host.")
        }
    }
}
