package com.hermexapp.android.network

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

@Serializable
private data class NewSessionRequest(
    val workspace: String? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    val profile: String? = null,
)
