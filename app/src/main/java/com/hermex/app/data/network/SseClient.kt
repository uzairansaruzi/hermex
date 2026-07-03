package com.hermex.app.data.network

import com.hermex.app.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import okhttp3.*
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
    private var activeSource: EventSource? = null

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
                if (sseEvent != null) {
                    channel.trySend(sseEvent)
                }
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                if (t != null) {
                    channel.trySend(SSEEvent.Error(t.message ?: "Connection failed"))
                }
                channel.close()
            }

            override fun onClosed(eventSource: EventSource) {
                channel.close()
            }
        }

        val source = factory.newEventSource(request, listener)
        activeSource = source

        try {
            for (event in channel) {
                emit(event)
                if (event is SSEEvent.StreamEnd || event is SSEEvent.Cancelled || event is SSEEvent.Error) {
                    break
                }
            }
        } finally {
            source.cancel()
            activeSource = null
        }
    }

    fun stop() {
        activeSource?.cancel()
        activeSource = null
    }

    private fun parseEvent(type: String?, data: String): SSEEvent? {
        if (data.isBlank() || data.startsWith(":")) return null // heartbeat

        return try {
            when (type) {
                "token" -> SSEEvent.Token(data)
                "reasoning" -> SSEEvent.Reasoning(data)
                "tool_call" -> {
                    val event = json.decodeFromString<ToolStreamEvent>(data)
                    SSEEvent.ToolStarted(event)
                }
                "tool_result" -> {
                    val event = json.decodeFromString<ToolStreamEvent>(data)
                    SSEEvent.ToolCompleted(event)
                }
                "title" -> SSEEvent.Title(data)
                "done" -> {
                    if (data.isBlank() || data == "{}") {
                        SSEEvent.Done(DoneStreamEvent())
                    } else {
                        SSEEvent.Done(json.decodeFromString<DoneStreamEvent>(data))
                    }
                }
                "approval_pending" -> SSEEvent.ApprovalPending(json.decodeFromString(data))
                "clarification_pending" -> SSEEvent.ClarificationPending(json.decodeFromString(data))
                "interim_assistant" -> SSEEvent.InterimAssistant(json.decodeFromString(data))
                "stream_end" -> SSEEvent.StreamEnd
                "cancel" -> SSEEvent.Cancelled
                "error" -> SSEEvent.Error(data)
                else -> null
            }
        } catch (e: Exception) {
            null
        }
    }
}
