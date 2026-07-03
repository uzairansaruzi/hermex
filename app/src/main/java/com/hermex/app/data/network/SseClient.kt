package com.hermex.app.data.network

import com.hermex.app.data.model.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SseClient @Inject constructor(
    private val okHttpClient: OkHttpClient,
    private val json: Json
) {
    fun stream(url: HttpUrl): Flow<SSEEvent> = flow {
        val channel = Channel<SSEEvent>(Channel.BUFFERED)

        val factory = EventSources.createFactory(okHttpClient)
        val request = Request.Builder()
            .url(url)
            .header("Accept", "text/event-stream")
            .header("Cache-Control", "no-cache, no-transform")
            .header("Accept-Encoding", "identity")
            .build()

        val listener = object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                val sseEvent = parseEvent(type, data)
                if (sseEvent != null) channel.trySend(sseEvent)
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                if (t != null) channel.trySend(SSEEvent.Error(t.message ?: "Connection failed"))
                channel.close()
            }

            override fun onClosed(eventSource: EventSource) {
                channel.close()
            }
        }

        val source = factory.newEventSource(request, listener)

        try {
            for (event in channel) {
                emit(event)
                if (event is SSEEvent.StreamEnd || event is SSEEvent.Cancelled || event is SSEEvent.Error) break
            }
        } finally {
            source.cancel()
        }
    }

    internal fun parseEvent(type: String?, data: String): SSEEvent? {
        if (data.isBlank() || data.startsWith(":")) return null

        return try {
            when (type) {
                "token" -> SSEEvent.Token(textPayload(data))
                "reasoning" -> SSEEvent.Reasoning(textPayload(data))
                "tool", "tool_call", "tool_started" -> SSEEvent.ToolStarted(json.decodeFromString<ToolStreamEvent>(data))
                "tool_complete", "tool_result", "tool_completed" -> SSEEvent.ToolCompleted(json.decodeFromString<ToolStreamEvent>(data))
                "title" -> SSEEvent.Title(textPayload(data))
                "done" -> {
                    if (data.isBlank() || data == "{}") SSEEvent.Done(DoneStreamEvent())
                    else SSEEvent.Done(json.decodeFromString<DoneStreamEvent>(data))
                }
                "approval_pending" -> SSEEvent.ApprovalPending(json.decodeFromString(data))
                "clarification_pending" -> SSEEvent.ClarificationPending(json.decodeFromString(data))
                "interim_assistant" -> SSEEvent.InterimAssistant(json.decodeFromString(data))
                "stream_end" -> SSEEvent.StreamEnd
                "cancel" -> SSEEvent.Cancelled
                "error" -> SSEEvent.Error(textPayload(data))
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun textPayload(data: String): String {
        val element = runCatching { json.parseToJsonElement(data) }.getOrNull() ?: return data
        return element.textValue() ?: data
    }

    private fun JsonElement.textValue(): String? = when (this) {
        is JsonPrimitive -> contentOrNull
        is JsonObject -> {
            val preferredKeys = listOf("text", "content", "delta", "message", "title", "error")
            preferredKeys.firstNotNullOfOrNull { key -> this[key]?.textValue()?.takeIf(String::isNotBlank) }
                ?: toString()
        }
        is JsonArray -> mapNotNull { it.textValue()?.takeIf(String::isNotBlank) }
            .joinToString("\n\n")
            .takeIf(String::isNotBlank)
        else -> null
    }
}
