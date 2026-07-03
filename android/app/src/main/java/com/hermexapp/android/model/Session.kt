package com.hermexapp.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

// Shapes mirror the iOS models (Session.swift), which are verified against the
// pinned upstream `api/models.py` / `api/routes.py`. Every field is nullable
// with a default (hard rule #3); the app's shared Json config additionally
// ignores unknown keys, accepts lenient primitives, and coerces nulls.

/** `GET /api/sessions`. */
@Serializable
data class SessionsResponse(
    val sessions: List<SessionSummary>? = null,
    @SerialName("cli_count") val cliCount: Int? = null,
)

/** `GET /api/sessions/search?q=…&content=…&depth=…`. */
@Serializable
data class SessionSearchResponse(
    val sessions: List<SessionSummary>? = null,
    val query: String? = null,
    val count: Int? = null,
)

/** `GET /api/session?session_id=…` and `POST /api/session/new`. */
@Serializable
data class SessionResponse(
    val session: SessionDetail? = null,
    val error: String? = null,
)

@Serializable
data class SessionSummary(
    @SerialName("session_id") val sessionId: String? = null,
    val title: String? = null,
    val workspace: String? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    @SerialName("message_count") val messageCount: Int? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    @SerialName("updated_at") val updatedAt: Double? = null,
    @SerialName("last_message_at") val lastMessageAt: Double? = null,
    val pinned: Boolean? = null,
    val archived: Boolean? = null,
    @SerialName("project_id") val projectId: String? = null,
    val profile: String? = null,
    @SerialName("active_stream_id") val activeStreamId: String? = null,
    @SerialName("is_streaming") val isStreaming: Boolean? = null,
    @SerialName("is_cli_session") val isCliSession: Boolean? = null,
    @SerialName("source_tag") val sourceTag: String? = null,
    @SerialName("session_source") val sessionSource: String? = null,
    @SerialName("source_label") val sourceLabel: String? = null,
) {
    /** Stable list identity mirroring the iOS `SessionSummary.id`. */
    val stableId: String
        get() = sessionId?.takeIf { it.isNotEmpty() }
            ?: "session-${title?.trim() ?: "untitled"}-${createdAt ?: updatedAt ?: lastMessageAt ?: 0.0}"

    /**
     * True when this row originates from a scheduled cron job — mirrors the
     * iOS `isCronSession` (upstream `is_cron_session` in `api/models.py`).
     */
    val isCronSession: Boolean
        get() {
            if (sessionId?.trim()?.lowercase()?.startsWith("cron_") == true) return true
            return listOf(sessionSource, sourceTag, sourceLabel)
                .mapNotNull { it?.trim()?.lowercase() }
                .contains("cron")
        }
}

@Serializable
data class SessionDetail(
    @SerialName("session_id") val sessionId: String? = null,
    val title: String? = null,
    val workspace: String? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    @SerialName("message_count") val messageCount: Int? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    @SerialName("updated_at") val updatedAt: Double? = null,
    @SerialName("last_message_at") val lastMessageAt: Double? = null,
    val pinned: Boolean? = null,
    val archived: Boolean? = null,
    @SerialName("project_id") val projectId: String? = null,
    val profile: String? = null,
    @SerialName("active_stream_id") val activeStreamId: String? = null,
    @SerialName("pending_user_message") val pendingUserMessage: String? = null,
    @SerialName("context_length") val contextLength: Int? = null,
    @SerialName("is_cli_session") val isCliSession: Boolean? = null,
    // Raw elements so one malformed message never throws away the whole
    // transcript — mirrors the iOS `decodeMessagesTolerantly`.
    val messages: List<JsonElement>? = null,
    @SerialName("_messages_truncated") val messagesTruncated: Boolean? = null,
    @SerialName("_messages_offset") val messagesOffset: Int? = null,
) {
    /** Per-element tolerant decode of the transcript. */
    fun chatMessages(json: Json): List<ChatMessage> =
        messages.orEmpty().mapNotNull { element ->
            try {
                json.decodeFromJsonElement(ChatMessage.serializer(), element)
            } catch (_: Exception) {
                null
            }
        }
}

/** `GET /api/session/status?session_id=…`. */
@Serializable
data class SessionStatusResponse(
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("active_stream_id") val activeStreamId: String? = null,
    @SerialName("is_streaming") val isStreaming: Boolean? = null,
    @SerialName("pending_user_message") val pendingUserMessage: String? = null,
    val error: String? = null,
)
