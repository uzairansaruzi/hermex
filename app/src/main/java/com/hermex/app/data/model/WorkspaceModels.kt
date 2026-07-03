package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WorkspaceEntry(
    val name: String? = null,
    val path: String? = null,
    val type: String? = null,
    @SerialName("is_dir") val isDir: Boolean? = null,
    val size: Long? = null,
    @SerialName("modified_at") val modifiedAt: Double? = null
) {
    val isDirectory: Boolean
        get() = isDir == true || type == "directory" || type == "dir"
}

@Serializable
data class FileListResponse(
    val entries: List<WorkspaceEntry>? = null
)

@Serializable
data class FileContentResponse(
    val content: String? = null,
    val path: String? = null,
    val size: Long? = null,
    @SerialName("modified_at") val modifiedAt: Double? = null,
    val encoding: String? = null
)

@Serializable
data class GitStatusEnvelope(
    val git: GitStatusResponse? = null
)

@Serializable
data class GitStatusResponse(
    val branch: String? = null,
    val dirty: Int? = null,
    val modified: Int? = null,
    val untracked: Int? = null,
    val staged: Int? = null,
    val upstream: String? = null,
    val ahead: Int? = null,
    val behind: Int? = null,
    @SerialName("is_git") val isGit: Boolean? = null,
    val totals: GitTotals? = null,
    val files: List<GitFileStatus>? = null,
    val truncated: Boolean? = null
) {
    @kotlinx.serialization.Transient
    val modifiedCount: Int = totals?.unstaged ?: modified ?: files.orEmpty().count { it.unstaged == true && it.ignored != true }
    @kotlinx.serialization.Transient
    val stagedCount: Int = totals?.staged ?: staged ?: files.orEmpty().count { it.staged == true && it.ignored != true }
    @kotlinx.serialization.Transient
    val untrackedCount: Int = totals?.untracked ?: untracked ?: files.orEmpty().count { it.untracked == true && it.ignored != true }
}

@Serializable
data class GitTotals(
    val changed: Int? = null,
    val staged: Int? = null,
    val unstaged: Int? = null,
    val untracked: Int? = null,
    val conflicts: Int? = null
)

@Serializable
data class GitFileStatus(
    val path: String? = null,
    @SerialName("old_path") val oldPath: String? = null,
    @SerialName("workspace_path") val workspacePath: String? = null,
    val status: String? = null,
    val staged: Boolean? = null,
    val unstaged: Boolean? = null,
    val untracked: Boolean? = null,
    val ignored: Boolean? = null,
    val conflict: Boolean? = null,
    val additions: Int? = null,
    val deletions: Int? = null,
    val binary: Boolean? = null
)

@Serializable
data class GitBranchesResponse(
    val branches: List<String>? = null,
    val current: String? = null
)

@Serializable
data class GitDiffResponse(
    val diff: String? = null
)

@Serializable
data class GitCommitRequest(
    @SerialName("session_id") val sessionId: String,
    val message: String
)

@Serializable
data class GitCommitResponse(
    val ok: Boolean? = null,
    val sha: String? = null,
    val error: String? = null
)

@Serializable
data class TurnFileChangeSummary(
    val path: String? = null,
    val type: String? = null,
    @SerialName("lines_added") val linesAdded: Int? = null,
    @SerialName("lines_removed") val linesRemoved: Int? = null
)
