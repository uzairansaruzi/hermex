package com.hermexapp.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/**
 * One transcript message — mirrors the iOS `ChatMessage`. `content` stays a
 * raw [JsonElement] because upstream sends either a plain string or an array
 * of typed parts; [textContent] extracts the displayable text either way.
 */
@Serializable
data class ChatMessage(
    val role: String? = null,
    val content: JsonElement? = null,
    val timestamp: Double? = null,
    @SerialName("_ts") val underscoredTimestamp: Double? = null,
    @SerialName("message_id") val messageId: String? = null,
    val name: String? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    @SerialName("tool_use_id") val toolUseId: String? = null,
    @SerialName("tool_calls") val toolCalls: List<JsonElement>? = null,
    val reasoning: String? = null,
) {
    /** Prefers the raw `_ts` stamp, like the iOS decoder. */
    val effectiveTimestamp: Double? get() = underscoredTimestamp ?: timestamp

    /** Stable identity mirroring the iOS `ChatMessage.id`. */
    val stableId: String
        get() = messageId ?: "${role ?: "unknown"}-${effectiveTimestamp ?: 0.0}-${textContent ?: ""}"

    /**
     * Displayable text: a string content verbatim; an array of parts joined
     * from its `{"type":"text","text":…}` members and bare strings (mirrors
     * the iOS `textContent(from:)`); anything else is not displayable text.
     */
    val textContent: String?
        get() = when (content) {
            null -> null
            is JsonPrimitive -> content.contentOrNull
            is JsonArray -> content
                .mapNotNull { part ->
                    when (part) {
                        is JsonPrimitive -> part.contentOrNull
                        is JsonObject ->
                            if ((part["type"] as? JsonPrimitive)?.contentOrNull == "text") {
                                (part["text"] as? JsonPrimitive)?.contentOrNull
                            } else {
                                null
                            }
                        else -> null
                    }
                }
                .joinToString(separator = "")
                .trim()
                .ifEmpty { null }
            is JsonObject -> content.jsonObject.toString()
        }

    /** A user message with no visible text or attachments is a tool result row. */
    val hasVisibleUserContent: Boolean
        get() = role == "user" && !textContent.isNullOrBlank()
}

/** `POST /api/chat/start`. */
@Serializable
data class ChatStartResponse(
    @SerialName("stream_id") val streamId: String? = null,
    @SerialName("session_id") val sessionId: String? = null,
    val error: String? = null,
)

/** `GET /api/chat/cancel?stream_id=…`. */
@Serializable
data class ChatCancelResponse(
    val ok: Boolean? = null,
    val cancelled: Boolean? = null,
    @SerialName("stream_id") val streamId: String? = null,
    val error: String? = null,
)

/** `POST /api/chat/steer`. */
@Serializable
data class ChatSteerResponse(
    val ok: Boolean? = null,
    val error: String? = null,
)
