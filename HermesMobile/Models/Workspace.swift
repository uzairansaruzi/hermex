import Foundation

struct WorkspacesResponse: Decodable, Equatable {
    let workspaces: [WorkspaceRoot]?
    let last: String?
}

struct WorkspaceSuggestionsResponse: Decodable, Equatable {
    let suggestions: [String]?
    let prefix: String?
}

struct WorkspaceRoot: Decodable, Equatable, Sendable {
    let path: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case path
        case name
    }

    init(from decoder: Decoder) throws {
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            path = stringValue
            name = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

/// Response shape shared by the four workspace-registry mutation routes
/// (`/api/workspaces/add|remove|rename|reorder`). Verified against upstream
/// `_handle_workspace_*` handlers: `{"ok": true, "workspaces": [...]}` on success.
/// These routes are undocumented (not on the official docs site), so every field
/// stays optional and callers must tolerate a missing `workspaces` echo.
struct WorkspaceMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let workspaces: [WorkspaceRoot]?
    let error: String?
}

/// Surfaced when a mutation route answers with HTTP success but reports
/// `ok: false` in the body. Upstream signals failure via non-2xx today, but
/// these routes are undocumented, so an explicit body-level failure must not
/// be presented as a success. Reuses the phrasing (and localization keys) of
/// `APIError`'s 400 handling.
struct WorkspaceMutationRejection: LocalizedError, Equatable {
    let serverMessage: String?

    var errorDescription: String? {
        if let serverMessage, !serverMessage.isEmpty {
            return String(localized: "The server rejected the request: \(serverMessage)")
        }
        return String(localized: "The server rejected the request.")
    }
}

struct AddWorkspaceRequest: Encodable, Equatable {
    let path: String
    let name: String?
    let create: Bool?
}

struct RemoveWorkspaceRequest: Encodable, Equatable {
    let path: String
}

struct RenameWorkspaceRequest: Encodable, Equatable {
    let path: String
    let name: String
}

struct ReorderWorkspacesRequest: Encodable, Equatable {
    let paths: [String]
}

struct DirectoryListResponse: Decodable, Equatable {
    let entries: [WorkspaceEntry]?
    let path: String?
    let workspace: String?
    let error: String?
}

struct WorkspaceEntry: Decodable, Equatable, Identifiable {
    var id: String { path ?? name ?? UUID().uuidString }
    var isBrowsableDirectory: Bool {
        isDirectory == true || type == "dir"
    }

    let name: String?
    let path: String?
    let type: String?
    let size: Int?
    let modified: Double?
    let isDirectory: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case type
        case size
        case modified
        case isDirectory
        case isDir
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        modified = try container.decodeIfPresent(Double.self, forKey: .modified)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory)
            ?? container.decodeIfPresent(Bool.self, forKey: .isDir)
    }
}

struct FileResponse: Decodable, Equatable {
    let content: String?
    let path: String?
    let name: String?
    let language: String?
    let size: Int?
    let lines: Int?
    let error: String?
}
