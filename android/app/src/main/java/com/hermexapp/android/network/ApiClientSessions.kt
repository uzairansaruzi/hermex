package com.hermexapp.android.network

import com.hermexapp.android.model.SessionMutationResponse
import com.hermexapp.android.model.SessionResponse
import com.hermexapp.android.model.SessionSearchResponse
import com.hermexapp.android.model.SessionStatusResponse
import com.hermexapp.android.model.SessionsResponse
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

// Session endpoints, mirroring the iOS `APIClient+Sessions` — paths and query
// names verified against the iOS Endpoint enum / pinned upstream routes.

suspend fun ApiClient.sessions(): SessionsResponse = getJson(Endpoint.SESSIONS)

suspend fun ApiClient.searchSessions(
    query: String,
    content: Boolean = true,
    depth: Int = 5,
): SessionSearchResponse = getJson(
    Endpoint.SESSIONS_SEARCH,
    mapOf("q" to query, "content" to if (content) "1" else "0", "depth" to depth.toString()),
)

suspend fun ApiClient.session(
    id: String,
    includeMessages: Boolean = true,
    messageLimit: Int? = 50,
): SessionResponse {
    val query = buildMap {
        put("session_id", id)
        put("messages", if (includeMessages) "1" else "0")
        messageLimit?.let { put("msg_limit", it.toString()) }
    }
    return getJson(Endpoint.SESSION, query)
}

suspend fun ApiClient.sessionStatus(id: String): SessionStatusResponse =
    getJson(Endpoint.SESSION_STATUS, mapOf("session_id" to id))

suspend fun ApiClient.createSession(
    workspace: String? = null,
    model: String? = null,
    modelProvider: String? = null,
    profile: String? = null,
): SessionResponse = postJson(
    Endpoint.SESSION_NEW,
    ApiJson.encodeToString(
        NewSessionRequest(workspace, model, modelProvider, profile),
    ),
)

suspend fun ApiClient.renameSession(id: String, title: String): SessionMutationResponse =
    postJson(Endpoint.SESSION_RENAME, ApiJson.encodeToString(RenameSessionRequest(id, title)))

suspend fun ApiClient.deleteSession(id: String): SessionMutationResponse =
    postJson(Endpoint.SESSION_DELETE, ApiJson.encodeToString(SessionIdRequest(id)))

suspend fun ApiClient.pinSession(id: String, pinned: Boolean): SessionMutationResponse =
    postJson(Endpoint.SESSION_PIN, ApiJson.encodeToString(PinSessionRequest(id, pinned)))

suspend fun ApiClient.archiveSession(id: String, archived: Boolean): SessionMutationResponse =
    postJson(Endpoint.SESSION_ARCHIVE, ApiJson.encodeToString(ArchiveSessionRequest(id, archived)))

/** Deep-copies a session server-side into an independent "(copy)". */
suspend fun ApiClient.duplicateSession(id: String): SessionResponse =
    postJson(Endpoint.SESSION_DUPLICATE, ApiJson.encodeToString(SessionIdRequest(id)))

/** Moves a session into [projectId] (null → un-filed / no project). */
suspend fun ApiClient.moveSession(id: String, projectId: String?): SessionMutationResponse =
    postJson(Endpoint.SESSION_MOVE, ApiJson.encodeToString(MoveSessionRequest(id, projectId)))

/**
 * Forks a session from a message point (#465). [keepCount] null copies the full
 * history; 0 forks an empty conversation. [title] defaults to "<orig> (fork)".
 */
suspend fun ApiClient.branchSession(
    id: String,
    keepCount: Int? = null,
    title: String? = null,
): com.hermexapp.android.model.SessionBranchResponse =
    postJson(Endpoint.SESSION_BRANCH, ApiJson.encodeToString(BranchSessionRequest(id, keepCount, title)))

@Serializable
private data class NewSessionRequest(
    val workspace: String? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    val profile: String? = null,
)

@Serializable
private data class RenameSessionRequest(
    @SerialName("session_id") val sessionId: String,
    val title: String,
)

@Serializable
private data class SessionIdRequest(@SerialName("session_id") val sessionId: String)

@Serializable
private data class PinSessionRequest(
    @SerialName("session_id") val sessionId: String,
    val pinned: Boolean,
)

@Serializable
private data class ArchiveSessionRequest(
    @SerialName("session_id") val sessionId: String,
    val archived: Boolean,
)

@Serializable
private data class MoveSessionRequest(
    @SerialName("session_id") val sessionId: String,
    @SerialName("project_id") val projectId: String? = null,
)

@Serializable
private data class BranchSessionRequest(
    @SerialName("session_id") val sessionId: String,
    @SerialName("keep_count") val keepCount: Int? = null,
    val title: String? = null,
)
