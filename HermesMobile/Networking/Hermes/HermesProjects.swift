import Foundation

/// A Hermes Profile's project lanes from one `projects.tree` reply (#1052). A Hermes project is
/// a set of host folders, and a session belongs to the project with the deepest folder its
/// working folder sits in; the host derives that, so the list only reads it. Lanes are the
/// user's projects, then the automatic per-repository ones the host groups the rest into, in
/// the host's order. The "No project" bucket is not a lane: it is the unfiltered list. A node
/// without an id is skipped, and unknown fields are ignored.
struct HermesProjectTree: Equatable {
    static let noProjectID = "__no_project__"

    let projects: [ProjectSummary]
    /// The lane that claims each session, by the session's `id` (a compression chain's tip,
    /// as the list's rows name it).
    let owners: [String: String]

    init(reply: BotJSON) {
        var user: [ProjectSummary] = [], automatic: [ProjectSummary] = []
        var owners: [String: String] = [:]
        for node in reply["projects"].list ?? [] {
            guard let id = node["id"].text, !id.isEmpty, node["isNoProject"].flag != true, id != Self.noProjectID
            else { continue }
            let sessionIDs = (node["sessionIds"].list ?? []).compactMap(\.text).filter { !$0.isEmpty }
            for sessionID in sessionIDs where owners[sessionID] == nil { owners[sessionID] = id }
            let isAutomatic = node["isAuto"].flag == true
            let project = ProjectSummary(
                projectId: id, name: node["label"].text.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                color: node["color"].text.flatMap { $0.isEmpty ? nil : $0 },
                hermes: ProjectSummary.Hermes(
                    folder: node["path"].text.flatMap { $0.isEmpty ? nil : $0 }, isAutomatic: isAutomatic,
                    sessionCount: node["sessionCount"].integer ?? sessionIDs.count, claimedCount: sessionIDs.count
                )
            )
            if isAutomatic { automatic.append(project) } else { user.append(project) }
        }
        projects = user + automatic
        self.owners = owners
    }
}

/// The host folders that complete a typed path in the Hermes create sheet's folder field
/// (#1052), from `complete.path` outside any session.
enum HermesFolderCompletion {
    /// The most entries `complete.path` lists for one folder: files too, in name order with the
    /// hidden ones first (`_dir_listing_items` at the pin).
    static let hostListingLimit = 30

    /// What the folder field offers for one typed path.
    struct Suggestions: Equatable {
        /// Each as the typed parent plus the folder's name and `/`, so the user can keep typing.
        var folders: [String] = []
        /// The host's listing stopped at its limit before it reached a folder to offer, as in a
        /// home folder with many hidden entries. Typing more of the name narrows the listing.
        var needsMoreTyping = false
    }

    /// Whether `word` can be completed: a path from the host's root or home, so it never
    /// depends on which folder the host picks when no session names one.
    static func completes(_ word: String) -> Bool {
        (word.hasPrefix("/") || word.hasPrefix("~/")) && !word.contains(where: \.isNewline)
    }

    /// The folders under the typed path's parent whose names start with its last part. Hidden
    /// folders show only once their leading `.` is typed.
    static func suggestions(from reply: BotJSON, typed word: String) -> Suggestions {
        guard let slash = word.lastIndex(of: "/") else { return Suggestions() }
        let parent = word[...slash]
        let showsHidden = word[word.index(after: slash)...].hasPrefix(".")
        let items = reply["items"].list ?? []
        let folders: [String] = items.compactMap { item in
            guard item["meta"].text == "dir", var name = item["display"].text ?? item["text"].text else { return nil }
            while name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, !name.contains("/"), showsHidden || !name.hasPrefix(".") else { return nil }
            return parent + name + "/"
        }
        return Suggestions(folders: folders, needsMoreTyping: folders.isEmpty && items.count >= hostListingLimit)
    }
}

extension HermesFolderCompletion {
    /// The folders a Hermes chat's folder picker offers before anything is typed (#1117): the
    /// chat's `current` folder, the user's project folders from `projects`, then the folders the
    /// Profile's recent `sessions` worked in, each once. Automatic lanes are left out, as are
    /// rows that name another Profile.
    static func choices(current: String?, projects: HermesProjectTree?, sessions: [HermesSessionRow],
                        profile: String) -> [String] {
        let projectFolders = (projects?.projects ?? []).compactMap { $0.hermes?.isAutomatic == false ? $0.hermes?.folder : nil }
        let recentFolders = sessions.compactMap { row -> String? in
            guard row.profile.map({ $0.isEmpty || $0 == profile }) ?? true else { return nil }
            return row.cwd
        }
        var seen = Set<String>()
        return ([current].compactMap { $0 } + projectFolders + recentFolders).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
