package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class SessionsResponse(
    val sessions: List<SessionSummary>? = null,
    @SerialName("cli_count") val cliCount: Int? = null,
    @SerialName("server_time") val serverTime: Double? = null,
    @SerialName("server_tz") val serverTz: String? = null
)

@Serializable
data class SessionSummary(
    @SerialName("session_id") val sessionId: String? = null,
    val title: String? = null,
    @SerialName("last_message_at") val lastMessageAt: Double? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    @SerialName("updated_at") val updatedAt: Double? = null,
    val pinned: Boolean? = null,
    val archived: Boolean? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    val profile: String? = null,
    val workspace: String? = null,
    @SerialName("input_tokens") val inputTokens: Long? = null,
    @SerialName("output_tokens") val outputTokens: Long? = null,
    @SerialName("estimated_cost") val estimatedCost: Double? = null,
    @SerialName("project_id") val projectId: String? = null,
    @SerialName("project_name") val projectName: String? = null,
    val streaming: Boolean? = null,
    @SerialName("message_count") val messageCount: Int? = null
)

@Serializable
data class SessionResponse(
    val session: SessionDetail? = null
)

@Serializable
data class SessionDetail(
    @SerialName("session_id") val sessionId: String? = null,
    val title: String? = null,
    val messages: List<ChatMessage>? = null,
    @SerialName("messages_offset") val messagesOffset: Int? = null,
    @SerialName("messages_total") val messagesTotal: Int? = null,
    @SerialName("last_message_at") val lastMessageAt: Double? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    @SerialName("updated_at") val updatedAt: Double? = null,
    val model: String? = null,
    @SerialName("model_provider") val modelProvider: String? = null,
    val profile: String? = null,
    val workspace: String? = null,
    val pinned: Boolean? = null,
    val archived: Boolean? = null,
    val streaming: Boolean? = null,
    @SerialName("input_tokens") val inputTokens: Long? = null,
    @SerialName("output_tokens") val outputTokens: Long? = null,
    @SerialName("estimated_cost") val estimatedCost: Double? = null,
    @SerialName("context_length") val contextLength: Long? = null,
    @SerialName("threshold_tokens") val thresholdTokens: Long? = null,
    @SerialName("last_prompt_tokens") val lastPromptTokens: Long? = null,
    @SerialName("compression_anchor_content") val compressionAnchorContent: String? = null,
    @SerialName("compression_anchor_role") val compressionAnchorRole: String? = null
)

@Serializable
data class SessionMutationResponse(
    val ok: Boolean? = null,
    val session: SessionSummary? = null,
    val error: String? = null
)

@Serializable
data class ProjectsResponse(
    val projects: List<ProjectSummary>? = null
)

@Serializable
data class ProjectSummary(
    @SerialName("project_id") val projectId: String? = null,
    val name: String? = null,
    val color: String? = null,
    @SerialName("created_at") val createdAt: Double? = null
) {
    val id: String get() = projectId ?: name ?: java.util.UUID.randomUUID().toString()
}

@Serializable
data class ProjectMutationResponse(
    val ok: Boolean? = null,
    val project: ProjectSummary? = null,
    val error: String? = null
)
