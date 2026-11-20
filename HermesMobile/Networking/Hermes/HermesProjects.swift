import Foundation

struct HermesProjectTree: Equatable {
    static let noProjectID = "__no_project__"

    let projects: [ProjectSummary]
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

enum HermesFolderCompletion {
    static let hostListingLimit = 30

    struct Suggestions: Equatable {
        var folders: [String] = []
        var needsMoreTyping = false
    }

    static func completes(_ word: String) -> Bool {
        (word.hasPrefix("/") || word.hasPrefix("~/")) && !word.contains(where: \.isNewline)
    }

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
