package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

sealed class SSEEvent {
    data class Token(val text: String) : SSEEvent()
    data class Reasoning(val text: String) : SSEEvent()
    data class ToolStarted(val event: ToolStreamEvent) : SSEEvent()
    data class ToolCompleted(val event: ToolStreamEvent) : SSEEvent()
    data class Title(val title: String) : SSEEvent()
    data class Done(val event: DoneStreamEvent) : SSEEvent()
    data class ApprovalPending(val response: ApprovalPendingResponse) : SSEEvent()
    data class ClarificationPending(val response: ClarificationPendingResponse) : SSEEvent()
    data class InterimAssistant(val event: InterimAssistantStreamEvent) : SSEEvent()
    data class SteerLeftover(val text: String) : SSEEvent()
    data object StreamEnd : SSEEvent()
    data object Cancelled : SSEEvent()
    data class Error(val message: String) : SSEEvent()
}

@Serializable
data class ToolStreamEvent(
    @SerialName("tool_name") val toolName: String? = null,
    @SerialName("tool_id") val toolId: String? = null,
    val arguments: JsonElement? = null,
    val result: JsonElement? = null,
    val name: String? = null
)

@Serializable
data class DoneStreamEvent(
    val usage: UsageSnapshot? = null
)

@Serializable
data class UsageSnapshot(
    @SerialName("input_tokens") val inputTokens: Long? = null,
    @SerialName("output_tokens") val outputTokens: Long? = null,
    @SerialName("estimated_cost") val estimatedCost: Double? = null,
    @SerialName("context_length") val contextLength: Long? = null
)

@Serializable
data class ApprovalPendingResponse(
    val id: String? = null,
    @SerialName("session_id") val sessionId: String? = null,
    val type: String? = null,
    @SerialName("display_pattern_keys") val displayPatternKeys: List<String>? = null
)

@Serializable
data class ClarificationPendingResponse(
    val id: String? = null,
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("display_question") val displayQuestion: String? = null,
    @SerialName("display_choices") val displayChoices: List<String>? = null
)

@Serializable
data class InterimAssistantStreamEvent(
    val content: String? = null
)
