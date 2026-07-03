package com.hermex.app.data.network

import com.hermex.app.data.model.SSEEvent
import com.hermex.app.data.model.ToolStreamEvent
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SseClientTest {
    private val client = SseClient(
        okHttpClient = OkHttpClient(),
        json = Json { ignoreUnknownKeys = true }
    )

    @Test
    fun tokenEventsDecodeTextFromJsonPayload() {
        val event = client.parseEvent("token", "{\"text\":\"hello\"}")

        assertEquals(SSEEvent.Token("hello"), event)
    }

    @Test
    fun reasoningEventsDecodeTextFromJsonPayload() {
        val event = client.parseEvent("reasoning", "{\"text\":\"thinking\"}")

        assertEquals(SSEEvent.Reasoning("thinking"), event)
    }

    @Test
    fun toolEventsUseServerEventNames() {
        val started = client.parseEvent("tool", "{\"tool_name\":\"terminal\",\"tool_id\":\"tool-1\"}")
        val completed = client.parseEvent("tool_complete", "{\"tool_name\":\"terminal\",\"tool_id\":\"tool-1\",\"result\":{\"ok\":true}}");

        assertTrue(started is SSEEvent.ToolStarted)
        assertEquals("terminal", (started as SSEEvent.ToolStarted).event.toolName)
        assertTrue(completed is SSEEvent.ToolCompleted)
        assertEquals("tool-1", (completed as SSEEvent.ToolCompleted).event.toolId)
    }
}
