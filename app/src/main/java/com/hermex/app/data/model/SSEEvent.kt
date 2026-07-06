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

// ---------------------------------------------------------------------------
// Approval — wire format: {"pending": {...}, "pending_count": N}
// Event types: "approval" or "initial" (auto-detected)
// Matches iOS HermesMobile/Models/Approval.swift
// ---------------------------------------------------------------------------

@Serializable
data class ApprovalPendingResponse(
    val pending: PendingApproval? = null,
    @SerialName("pending_count") val pendingCount: Int? = null
) {
    /** UI convenience — surfaces pattern keys from the nested pending object. */
    val displayPatternKeys: List<String>?
        get() {
            val keys = pending?.patternKeys?.filter { it.isNotBlank() }
            if (!keys.isNullOrEmpty()) return keys
            val single = pending?.patternKey?.trim()?.takeIf { it.isNotEmpty() }
            return if (single != null) listOf(single) else null
        }

    val displayCommand: String? get() = pending?.command
    val displayDescription: String? get() = pending?.description
}

@Serializable
data class PendingApproval(
    @SerialName("approval_id") val approvalId: String? = null,
    val command: String? = null,
    val description: String? = null,
    @SerialName("pattern_key") val patternKey: String? = null,
    @SerialName("pattern_keys") val patternKeys: List<String>? = null
)

// ---------------------------------------------------------------------------
// Clarification — wire format: {"pending": {...}, "pending_count": N}
// Event types: "clarify" or "initial" (auto-detected)
// Matches iOS HermesMobile/Models/Clarification.swift
// ---------------------------------------------------------------------------

@Serializable
data class ClarificationPendingResponse(
    val pending: PendingClarification? = null,
    @SerialName("pending_count") val pendingCount: Int? = null
) {
    /** UI convenience — surfaces the question from the nested pending object. */
    val displayQuestion: String?
        get() = pending?.question?.trim()?.takeIf { it.isNotEmpty() }

    /** UI convenience — surfaces choices from the nested pending object. */
    val displayChoices: List<String>?
        get() = pending?.choicesOffered
            ?.mapNotNull { it.trim().takeIf(String::isNotEmpty) }
            ?.takeIf { it.isNotEmpty() }
}

@Serializable
data class PendingClarification(
    @SerialName("clarify_id") val clarifyId: String? = null,
    val question: String? = null,
    @SerialName("choices_offered") val choicesOffered: List<String>? = null,
    @SerialName("session_id") val sessionId: String? = null,
    val kind: String? = null,
    @SerialName("requested_at") val requestedAt: Double? = null,
    @SerialName("timeout_seconds") val timeoutSeconds: Int? = null,
    @SerialName("expires_at") val expiresAt: Double? = null
)

@Serializable
data class InterimAssistantStreamEvent(
    val content: String? = null
)
