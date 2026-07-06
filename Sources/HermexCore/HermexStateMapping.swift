import Foundation

public extension HermexJSONValue {
    var objectValue: [String: HermexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [HermexJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

public extension Dictionary where Key == String, Value == HermexJSONValue {
    func stringValue(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue { return value }
        }
        return nil
    }

    func boolValue(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = self[key]?.boolValue { return value }
        }
        return nil
    }

    func intValue(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key]?.intValue { return value }
        }
        return nil
    }

    func arrayValue(_ keys: String...) -> [HermexJSONValue] {
        for key in keys {
            if let array = self[key]?.arrayValue { return array }
        }
        return []
    }
}

public extension HermexWorkspaceState {
    static func fromDirectoryResponse(_ response: HermexJSONValue, fallbackPath: String?) -> HermexWorkspaceState {
        let object = response.objectValue ?? [:]
        let entries = object.arrayValue("entries", "files", "items")
            .compactMap(HermexWorkspaceEntryDTO.fromJSON)
        return HermexWorkspaceState(
            currentPath: object.stringValue("path", "workspace") ?? fallbackPath,
            entries: entries,
            isLoading: false,
            errorMessage: object.stringValue("error")
        )
    }
}

public extension HermexWorkspaceEntryDTO {
    static func fromJSON(_ value: HermexJSONValue) -> HermexWorkspaceEntryDTO? {
        guard let object = value.objectValue else { return nil }
        let path = object.stringValue("path", "workspace_path")
        let name = object.stringValue("name") ?? path?.split(separator: "/").last.map(String.init)
        guard let resolvedPath = path, let resolvedName = name else { return nil }
        let type = object.stringValue("type", "kind")
        let isDirectory = object.boolValue("is_directory", "is_dir", "directory")
            ?? (type == "dir" || type == "directory")
        return HermexWorkspaceEntryDTO(
            name: resolvedName,
            path: resolvedPath,
            type: type,
            isDirectory: isDirectory,
            size: object.intValue("size")
        )
    }
}

public extension HermexFilePreview {
    static func fromJSON(_ value: HermexJSONValue, fallbackPath: String) -> HermexFilePreview {
        let object = value.objectValue ?? [:]
        return HermexFilePreview(
            path: object.stringValue("path", "name") ?? fallbackPath,
            content: object.stringValue("content", "text"),
            mimeType: object.stringValue("mime_type", "mime", "language"),
            isBinary: object.boolValue("is_binary", "binary") ?? false
        )
    }
}

public extension HermexGitState {
    static func fromStatusResponse(_ response: HermexJSONValue) -> HermexGitState {
        let object = response.objectValue ?? [:]
        let files = object.arrayValue("files", "changes", "status")
            .compactMap(HermexGitFileChange.fromJSON)
        return HermexGitState(
            isRepository: object.boolValue("is_repo", "is_repository", "repository") ?? true,
            branch: object.stringValue("branch", "current_branch", "head"),
            upstream: object.stringValue("upstream", "tracking"),
            ahead: object.intValue("ahead"),
            behind: object.intValue("behind"),
            files: files,
            errorMessage: object.stringValue("error")
        )
    }

    static func diffText(from response: HermexJSONValue) -> String? {
        if let text = response.stringValue { return text }
        let object = response.objectValue ?? [:]
        return object.stringValue("diff", "patch", "text", "content")
    }

    func mergingStatus(from response: HermexJSONValue) -> HermexGitState {
        var updated = HermexGitState.fromStatusResponse(response)
        updated.diffPath = diffPath
        updated.diffText = diffText
        updated.commitMessage = commitMessage
        return updated
    }
}

public extension HermexGitFileChange {
    static func fromJSON(_ value: HermexJSONValue) -> HermexGitFileChange? {
        guard let object = value.objectValue else { return nil }
        guard let path = object.stringValue("path", "file", "workspace_path") else { return nil }
        return HermexGitFileChange(
            path: path,
            status: object.stringValue("status", "code") ?? "changed",
            additions: object.intValue("additions", "added"),
            deletions: object.intValue("deletions", "removed"),
            isStaged: object.boolValue("staged", "is_staged")
        )
    }
}

public extension HermexPanelsState {
    static func tasks(from response: HermexJSONValue, selectedPanel: HermexPanel = .tasks) -> HermexPanelsState {
        let object = response.objectValue ?? [:]
        let tasks = object.arrayValue("jobs", "crons", "tasks").compactMap(HermexTaskDTO.fromJSON)
        return HermexPanelsState(tasks: tasks, selectedPanel: selectedPanel, errorMessage: object.stringValue("error"))
    }

    static func skills(from response: HermexJSONValue, selectedPanel: HermexPanel = .skills) -> HermexPanelsState {
        let object = response.objectValue ?? [:]
        let skills = object.arrayValue("skills", "items").compactMap(HermexSkillDTO.fromJSON)
        return HermexPanelsState(skills: skills, selectedPanel: selectedPanel, errorMessage: object.stringValue("error"))
    }

    static func memory(from response: HermexJSONValue, selectedPanel: HermexPanel = .memory) -> HermexPanelsState {
        let object = response.objectValue ?? [:]
        let sections = object.arrayValue("sections", "memory").compactMap(HermexMemorySectionDTO.fromJSON)
        let objectSections = object.compactMap { key, value -> HermexMemorySectionDTO? in
            guard !["sections", "memory", "error"].contains(key), let content = value.stringValue else { return nil }
            return HermexMemorySectionDTO(section: key, content: content)
        }
        return HermexPanelsState(memory: sections + objectSections, selectedPanel: selectedPanel, errorMessage: object.stringValue("error"))
    }
}

public extension HermexTaskDTO {
    static func fromJSON(_ value: HermexJSONValue) -> HermexTaskDTO? {
        guard let object = value.objectValue else { return nil }
        guard let id = object.stringValue("id", "job_id", "name") else { return nil }
        return HermexTaskDTO(
            id: id,
            title: object.stringValue("title", "name", "command"),
            status: object.stringValue("status", "state"),
            schedule: object.stringValue("schedule", "cron", "next_run")
        )
    }
}

public extension HermexSkillDTO {
    static func fromJSON(_ value: HermexJSONValue) -> HermexSkillDTO? {
        guard let object = value.objectValue else { return nil }
        guard let name = object.stringValue("name", "id") else { return nil }
        return HermexSkillDTO(
            name: name,
            enabled: object.boolValue("enabled", "is_enabled"),
            summary: object.stringValue("summary", "description")
        )
    }
}

public extension HermexMemorySectionDTO {
    static func fromJSON(_ value: HermexJSONValue) -> HermexMemorySectionDTO? {
        guard let object = value.objectValue else { return nil }
        guard let section = object.stringValue("section", "name", "id") else { return nil }
        return HermexMemorySectionDTO(section: section, content: object.stringValue("content", "text", "value") ?? "")
    }
}
