package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WorkspaceEntry(
    val name: String? = null,
    val path: String? = null,
    val type: String? = null,
    val size: Long? = null,
    @SerialName("modified_at") val modifiedAt: Double? = null
)

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
data class GitStatusResponse(
    val branch: String? = null,
    val dirty: Boolean? = null,
    @SerialName("untracked_count") val untrackedCount: Int? = null,
    @SerialName("modified_count") val modifiedCount: Int? = null,
    @SerialName("staged_count") val stagedCount: Int? = null
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
