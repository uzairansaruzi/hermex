import Foundation

@MainActor final class HermesGitClient: GitDataClient {
    typealias MessageWriter = @MainActor @Sendable (_ diff: String, _ recent: String, _ avoid: String?) async throws -> String
    typealias Dispatch = @MainActor @Sendable () throws -> Void
    typealias WriteOwner = @MainActor @Sendable () throws -> Dispatch

    let context: HermesWorkspaceContext
    nonisolated let reviewScope: String
    private let http: HermesConnection
    private let writeMessage: MessageWriter?
    private let writeOwner: WriteOwner?
    let writeLock: GitWriteLock?
    private var root: String?

    static let maximumDiffBytes = 512 * 1024
    static let messageDiffCharacters = 12_000
    static let selectedDiffCharacters = 120_000

    init(context: HermesWorkspaceContext, http: HermesConnection, writeMessage: MessageWriter? = nil,
         writeOwner: WriteOwner? = nil) {
        self.context = context
        reviewScope = "\(context.server.absoluteString)|hermes|\(context.profile)|\(context.storedKey)|\(context.cwd)"
        self.http = http
        self.writeMessage = writeMessage
        self.writeOwner = writeOwner
        self.writeLock = GitWriteLock()
    }

    nonisolated var isHermes: Bool { true }

    func info() async throws -> GitInfo? {
        guard let root = try await repositoryRoot() else { return nil }
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary.fields != nil else { return nil }
        let changed = summary["changed"].integer ?? 0
        let untracked = summary["untracked"].integer ?? 0
        return GitInfo(branch: Self.branch(summary), dirty: changed, modified: changed - untracked, untracked: untracked,
                       ahead: summary["ahead"].integer, behind: summary["behind"].integer, isGit: true)
    }

    func status() async throws -> GitStatus? {
        guard let root = try await repositoryRoot() else { return Self.notARepository }
        return try await currentStatus(root)
    }

    private func currentStatus(_ root: String) async throws -> GitStatus {
        async let summary = send(.gitStatus(repository: root))
        async let changes = send(.gitChanges(repository: root))
        let (summaryBody, changesBody) = try await (summary, changes)
        return Self.status(summary: try Self.json(summaryBody), changes: try Self.json(changesBody))
    }

    func diff(for file: GitFile) async throws -> GitDiff? {
        guard let root = try await repositoryRoot() else { return nil }
        let path = file.displayPath
        let wholeChange = file.staged == true && file.unstaged == nil
        let kind = wholeChange ? nil : file.preferredDiffKind
        let request: HermesREST = wholeChange ? .gitFileDiff(repository: root, file: path)
            : .gitDiff(repository: root, file: path, staged: kind == "staged")
        let text = try Self.json(try await send(request))["diff"].text
        if wholeChange, text?.isEmpty != false, file.changeKind == .added {
            return try await currentContent(of: path, root: root)
        }
        return Self.diff(text, path: path, kind: kind)
    }

    func branchReview() async throws -> GitBranchReview? {
        guard let root = try await repositoryRoot() else { return nil }
        async let summary = send(.gitStatus(repository: root))
        async let changes = send(.gitBranchChanges(repository: root))
        let (summaryBody, changesBody) = try await (summary, changes)
        return Self.branchReview(summary: try Self.json(summaryBody), changes: try Self.json(changesBody))
    }

    func headSHA() async throws -> String? {
        guard let root = try await repositoryRoot() else { return nil }
        return Self.text(try Self.json(try await send(.gitHead(repository: root)))["sha"])
    }

    func changes(since base: String) async throws -> [GitFile]? {
        guard let root = try await repositoryRoot() else { return nil }
        let changes = try Self.json(try await send(.gitTurnChanges(repository: root, base: base)))
        guard Self.text(changes["base"]) == base else { return nil }
        return (changes["files"].list ?? []).compactMap { row in
            guard let path = row["path"].text, !path.isEmpty else { return nil }
            let untracked = row["status"].text == "?"
            return GitFile(path: path, status: untracked ? "?" : nil, staged: nil, unstaged: nil, untracked: untracked,
                           conflict: nil, additions: row["added"].integer, deletions: row["removed"].integer)
        }
    }

    func diff(for file: GitFile, in scope: GitReviewScope) async throws -> GitDiff? {
        let request: (_ root: String, _ path: String) -> HermesREST
        switch scope {
        case .uncommitted: return try await diff(for: file)
        case .branch: request = { .gitBranchDiff(repository: $0, file: $1) }
        case .since(let base): request = { .gitTurnDiff(repository: $0, file: $1, base: base) }
        }
        guard let root = try await repositoryRoot() else { return nil }
        let path = file.displayPath
        var text = try Self.json(try await send(request(root, path)))["diff"].text
        if case .since = scope, file.untracked == true, text?.isEmpty != false {
            text = try Self.json(try await send(.gitFileDiff(repository: root, file: path)))["diff"].text
        }
        return Self.diff(text, path: path, kind: nil)
    }

    nonisolated static func branchReview(summary: BotJSON, changes: BotJSON) -> GitBranchReview? {
        guard summary.fields != nil else { return nil }
        let files = (changes["files"].list ?? []).compactMap { row -> GitFile? in
            guard let path = row["path"].text, !path.isEmpty else { return nil }
            return GitFile(path: path, status: nil, staged: nil, unstaged: nil, untracked: nil, conflict: nil,
                           additions: row["added"].integer, deletions: row["removed"].integer)
        }
        return GitBranchReview(files: files, base: text(changes["base"]), branch: summary["branch"].text,
                               detached: summary["detached"].flag == true)
    }

    private static func diff(_ text: String?, path: String, kind: String?) -> GitDiff {
        let tooLarge = (text?.utf8.count ?? 0) > maximumDiffBytes
        return GitDiff(path: path, kind: kind, binary: isBinary(text ?? ""),
                       tooLarge: tooLarge, additions: nil, deletions: nil, diff: tooLarge ? nil : text)
    }

    private func currentContent(of path: String, root: String) async throws -> GitDiff {
        let file = try Self.json(try await send(.fsReadText(path: root + "/" + path)))
        let binary = file["binary"].flag == true
        let tooLarge = file["truncated"].flag == true
        let diff = file["text"].text.map { text in
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return "diff --git a/\(path) b/\(path)\n--- /dev/null\n+++ b/\(path)\n"
                + (lines.isEmpty ? "" : "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+\($0)\n" }.joined())
        }
        return GitDiff(path: path, kind: nil, binary: binary, tooLarge: tooLarge, additions: nil, deletions: nil,
                       diff: binary || tooLarge ? nil : diff)
    }

    func rowPath(forToolPath path: String) -> String {
        guard let root else { return path }
        return Self.rowPath(path, folder: context.cwd, root: root)
    }

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

    private nonisolated static func components(_ path: String) -> [String] {
        path.split(separator: "/").reduce(into: []) { parts, part in
            switch part {
            case ".": break
            case "..": _ = parts.popLast()
            default: parts.append(String(part))
            }
        }
    }

    nonisolated static func status(summary: BotJSON, changes: BotJSON) -> GitStatus {
        guard summary.fields != nil else { return notARepository }
        var flags: [String: BotJSON] = [:]
        for entry in summary["files"].list ?? [] {
            if let path = entry["path"].text { flags[path] = entry }
        }
        let rows = changes["files"].list
        let files = (rows ?? []).compactMap { row -> GitFile? in
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
                         behind: summary["behind"].integer, totals: totals, files: files, truncated: rows == nil ? nil : false)
    }

    private nonisolated static let notARepository = GitStatus(isGit: false, branch: nil, upstream: nil, ahead: nil,
                                                              behind: nil, totals: nil, files: nil, truncated: nil)

    private nonisolated static func branch(_ summary: BotJSON) -> String? {
        summary["branch"].text ?? (summary["detached"].flag == true ? "HEAD" : nil)
    }

    private nonisolated static func isBinary(_ text: String) -> Bool {
        !text.contains("\n@@") && text.split(separator: "\n").contains { $0.hasPrefix("Binary files ") && $0.hasSuffix(" differ") }
    }

    func stage(_ files: [GitFile]) async throws -> GitStatus? {
        try await writing(files) { root, rows, dispatch in
            guard !rows.contains(where: { $0.conflict == true }) else { throw HermesGitRefusal.conflictedStage }
            for row in rows where row.staged != true || row.unstaged != false {
                try await self.write(.gitStage(repository: root, file: row.path ?? ""), dispatch)
            }
        }
    }

    func unstage(_ files: [GitFile]) async throws -> GitStatus? {
        try await writing(files) { root, rows, dispatch in
            guard !rows.contains(where: Self.isRename) else { throw HermesGitRefusal.renamedUnstage }
            for row in rows where row.staged == true {
                try await self.write(.gitUnstage(repository: root, file: row.path ?? ""), dispatch)
            }
        }
    }

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

    private func committed(_ root: String, paths: [String]?, stagingRestored: Bool = true) async throws -> GitCommitResponse {
        let sha = (try? Self.json(try await send(.gitHead(repository: root)))).flatMap { Self.text($0["sha"]) }
        return GitCommitResponse(ok: true, commit: sha.map { String($0.prefix(7)) }, paths: paths,
                                 status: try? await status(), git: nil, stagingNotRestored: !stagingRestored)
    }

    func push() async throws -> GitRemoteActionResponse {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary["detached"].flag != true else { throw HermesGitRefusal.detachedHead }
        try await write(.gitPush(repository: root), dispatch, deadline: .provisioning)
        return GitRemoteActionResponse(ok: true, message: nil, status: try? await status())
    }

    static let syncRoutes = ["POST /git/fetch", "POST /git/pull", "POST /git/branch"]

    func supportsSync() async -> Bool {
        guard let routes = try? await BotDashboardClient(http: http).companionRoutes() else { return false }
        return Self.syncRoutes.allSatisfy(routes.supports)
    }

    func fetch() async throws -> GitRemoteActionResponse {
        try await sync(HermesREST.gitFetch)
    }

    func pull() async throws -> GitRemoteActionResponse {
        try await sync(HermesREST.gitPull)
    }

    private func sync(_ request: (String) -> HermesREST) async throws -> GitRemoteActionResponse {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        try await write(request(root), dispatch, deadline: .provisioning)
        return GitRemoteActionResponse(ok: true, message: nil, status: try? await status())
    }

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

    func branches() async throws -> GitBranches? {
        guard let root = try await repositoryRoot() else { return nil }
        let rows = try Self.json(try await send(.gitBranches(repository: root)))["branches"].list ?? []
        let refs = { (remote: Bool) in
            rows.filter { ($0["isRemote"].flag == true) == remote }.compactMap { row in
                Self.text(row["name"]).map {
                    GitBranchRef(name: $0, sha: nil, updated: nil, updatedRelative: nil, author: nil, subject: nil,
                                 upstream: nil, ahead: nil, behind: nil)
                }
            }
        }
        return GitBranches(isGit: true, current: nil, detached: nil, head: nil, local: refs(false), remote: refs(true),
                           upstream: nil, ahead: nil, behind: nil)
    }

    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool) async throws -> GitCheckoutResponse {
        if let name = target.newBranch {
            guard HermesREST.isBranchName(name), !stashingChanges else { throw HermesGitRefusal.failed }
            let dispatch = try beginWrite()
            let root = try await writableRoot()
            try await write(.gitCreateBranch(repository: root, name: name), dispatch, deadline: .provisioning)
            return Self.switched(to: name, status: try? await status())
        }
        let remote = target.mode != .local
        let branch = remote ? Self.shortName(target.ref) : target.ref
        guard let branch, HermesREST.isBranchName(branch), !stashingChanges else {
            throw HermesGitRefusal.failed
        }
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        if remote {
            let rows = try Self.json(try await send(.gitBranches(repository: root)))["branches"].list ?? []
            let named = rows.filter { row in
                Self.text(row["name"]).flatMap { row["isRemote"].flag == true ? Self.shortName($0) : $0 } == branch
            }
            guard named.count == 1, named[0]["isRemote"].flag == true, Self.text(named[0]["name"]) == target.ref else {
                throw HermesGitRefusal.failed
            }
        }
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary["changed"].integer == 0 else { throw HermesGitRefusal.uncommittedSwitch }
        try await write(.gitSwitchBranch(repository: root, branch: branch), dispatch, deadline: .provisioning)
        return Self.switched(to: branch, status: try? await status())
    }

    func pullRequest() async throws -> GitPullRequest? {
        guard let root = try await repositoryRoot() else { return nil }
        return Self.pullRequest(try Self.json(try await send(.gitShipInfo(repository: root)))["pr"])
    }

    private nonisolated static func pullRequest(_ pr: BotJSON) -> GitPullRequest? {
        guard let number = pr["number"].integer, number > 0,
              let url = Self.text(pr["url"]).flatMap(URL.init(string:)), InAppBrowserPolicy.opensInApp(url)
        else { return nil }
        return GitPullRequest(number: number, url: url, state: Self.text(pr["state"]).flatMap(GitPullRequest.State.init))
    }

    private nonisolated static func switched(to branch: String, status: GitStatus?) -> GitCheckoutResponse {
        GitCheckoutResponse(ok: true, message: nil, status: status, git: nil, branches: nil, currentBranch: branch,
                            stashName: nil, stashed: nil, restoredStash: nil, restoreFailed: nil, restoreError: nil,
                            restoreStash: nil)
    }

    private nonisolated static func shortName(_ ref: String) -> String? {
        ref.firstIndex(of: "/").map { String(ref[ref.index(after: $0)...]) }
    }

    private nonisolated static func isNew(_ file: GitFile) -> Bool {
        file.untracked == true || file.changeKind == .added
    }

    private nonisolated static func isRename(_ file: GitFile) -> Bool {
        ["R", "C"].contains((file.status ?? "").uppercased().first.map(String.init) ?? "")
    }

    private nonisolated static func text(_ value: BotJSON) -> String? {
        value.text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func writing(_ files: [GitFile],
                         _ writes: (String, [GitFile], @escaping Dispatch) async throws -> Void) async throws -> GitStatus? {
        let dispatch = try beginWrite()
        let root = try await writableRoot()
        let rows = try Self.rows(for: files, in: try await currentStatus(root).files ?? [])
        try await writes(root, rows, dispatch)
        return try? await status()
    }

    private nonisolated static func rows(for files: [GitFile], in current: [GitFile]) throws -> [GitFile] {
        try files.compactMap { file in
            guard let path = file.path, HermesREST.isGitFile(path) else { throw HermesGitRefusal.failed }
            let matches = current.filter { $0.path == path }
            guard matches.count < 2 else { throw HermesGitRefusal.failed }
            return matches.first
        }
    }

    private func beginWrite() throws -> Dispatch {
        guard let writeOwner else { return Self.unowned }
        return try writeOwner()
    }

    private static let unowned: Dispatch = {}

    private func writableRoot() async throws -> String {
        guard let root = try await repositoryRoot() else { throw HermesGitUnavailable() }
        return root
    }

    private func write(_ rest: HermesREST, _ dispatch: @escaping Dispatch,
                       deadline: HermesConnection.Deadline = .standard) async throws {
        _ = try await send(rest, deadline: deadline, refusal: HermesGitRefusal.failed) { [weak self] in
            try dispatch()
            self?.sentWrites += 1
        }
    }

    private var sentWrites = 0

    private func repositoryRoot() async throws -> String? {
        if let root { return root }
        let found = try Self.json(try await send(.gitRoot(path: context.cwd)))["root"].text
        root = found.flatMap { $0.isEmpty ? nil : $0 }
        return root
    }

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

struct HermesGitUnavailable: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "Repository status unavailable") }
}

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
    case partlyStagedSelection
    case firstCommitSelected
    case turnRunning
    case restoreFailed
    case uncommittedSwitch
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
        case .uncommittedSwitch: String(localized: "Commit or discard first.")
        case .failed: String(localized: "Git couldn’t finish this change on your Hermes host.")
        }
    }
}
