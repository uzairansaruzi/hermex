package com.hermex.app.data.model

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

@Serializable
data class ChatMessage(
    val role: String? = null,
    @Serializable(with = MessageContentAsStringSerializer::class)
    val content: String? = null,
    val timestamp: Double? = null,
    @SerialName("message_id") val messageId: String? = null,
    val name: String? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    @SerialName("tool_use_id") val toolUseId: String? = null,
    @SerialName("tool_calls") val toolCalls: List<JsonElement>? = null,
    @SerialName("content_parts") val contentParts: List<JsonElement>? = null,
    val reasoning: String? = null,
    val attachments: List<MessageAttachment>? = null,
    @SerialName("_ts") val ts: Double? = null
) {
    val id: String
        get() = messageId ?: "${role ?: "unknown"}-${effectiveTimestamp}-${content ?: ""}"

    val effectiveTimestamp: Double
        get() = ts ?: timestamp ?: 0.0
}

object MessageContentAsStringSerializer : KSerializer<String?> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(
        "MessageContentAsString",
        PrimitiveKind.STRING
    )

    override fun deserialize(decoder: Decoder): String? {
        val jsonDecoder = decoder as? JsonDecoder ?: return decoder.decodeString()
        return jsonElementToText(jsonDecoder.decodeJsonElement())
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: String?) {
        if (value == null) {
            encoder.encodeNull()
        } else {
            encoder.encodeString(value)
        }
    }

    private fun jsonElementToText(element: JsonElement): String? {
        return when (element) {
            JsonNull -> null
            is JsonPrimitive -> element.contentOrNull
            is JsonArray -> element.mapNotNull(::jsonElementToText)
                .filter { it.isNotBlank() }
                .joinToString("\n\n")
                .takeIf { it.isNotBlank() }
            is JsonObject -> objectContentToText(element)
        }
    }

    private fun objectContentToText(obj: JsonObject): String? {
        val preferred = listOf("text", "content", "message", "input", "output", "result")
            .firstNotNullOfOrNull { key -> obj[key]?.let(::jsonElementToText)?.takeIf(String::isNotBlank) }
        if (preferred != null) return preferred

        return obj.entries
            .filterNot { (key, _) -> key == "type" || key.startsWith("_") }
            .mapNotNull { (key, value) ->
                val text = jsonElementToText(value)?.takeIf(String::isNotBlank) ?: return@mapNotNull null
                "$key: $text"
            }
            .joinToString("\n")
            .takeIf { it.isNotBlank() }
    }
}

@Serializable
data class MessageAttachment(
    val path: String? = null,
    val filename: String? = null,
    val mime: String? = null,
    val size: Long? = null,
    @SerialName("is_image") val isImage: Boolean? = null,
    val url: String? = null
)

@Serializable
data class ChatStartRequest(
    @SerialName("session_id") val sessionId: String,
    val message: String,
    val workspace: String? = null,
    val model: String? = null,
    val attachments: List<ChatAttachment>? = null
)

@Serializable
data class ChatAttachment(
    val filename: String,
    val path: String,
    val mime: String? = null,
    val size: Long? = null,
    @SerialName("is_image") val isImage: Boolean? = null
)

@Serializable
data class ChatStartResponse(
    @SerialName("stream_id") val streamId: String? = null,
    @SerialName("session_id") val sessionId: String? = null
)

@Serializable
data class ChatSteerRequest(
    @SerialName("session_id") val sessionId: String,
    val text: String
)

@Serializable
data class ChatSteerResponse(
    val accepted: Boolean? = null,
    val fallback: String? = null,
    @SerialName("stream_id") val streamId: String? = null
)

@Serializable
data class StreamStatusResponse(
    val active: Boolean? = null,
    val done: Boolean? = null,
    val error: String? = null
)
