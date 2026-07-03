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

