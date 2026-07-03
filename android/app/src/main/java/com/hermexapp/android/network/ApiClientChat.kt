package com.hermexapp.android.network

import com.hermexapp.android.model.ChatCancelResponse
import com.hermexapp.android.model.ChatStartResponse
import com.hermexapp.android.model.ChatSteerResponse
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.HttpUrl

// Chat endpoints, mirroring the iOS `APIClient+Chat`.

suspend fun ApiClient.startChat(
    sessionId: String,
    message: String,
    workspace: String? = null,
    model: String? = null,
    modelProvider: String? = null,
    profile: String? = null,
): ChatStartResponse = postJson(
    Endpoint.CHAT_START,
    ApiJson.encodeToString(
        ChatStartRequest(sessionId, message, workspace, model, modelProvider, profile),
    ),
)

fun ApiClient.chatStreamUrl(streamId: String): HttpUrl =
    url(Endpoint.CHAT_STREAM, mapOf("stream_id" to streamId))

suspend fun ApiClient.cancelChat(streamId: String): ChatCancelResponse =
    getJson(Endpoint.CHAT_CANCEL, mapOf("stream_id" to streamId))

suspend fun ApiClient.steerChat(sessionId: String, text: String): ChatSteerResponse =
    postJson(
        Endpoint.CHAT_STEER,
        ApiJson.encodeToString(ChatSteerRequest(sessionId, text)),
    )

@Serializable
private data class ChatStartRequest(
    @SerialName("session_id") val sessionId: String,
    val message: String,
    val workspace: String? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    val profile: String? = null,
)

@Serializable
private data class ChatSteerRequest(
    @SerialName("session_id") val sessionId: String,
    val text: String,
)
