package com.hermexapp.android.model

import com.hermexapp.android.network.ApiJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionModelsDecodingTest {

    @Test
    fun `sessions response decodes upstream-shaped rows and ignores unknown fields`() {
        val payload = """
            {"sessions": [
                {"session_id": "abc", "title": "Fix the build", "model": "gpt-x",
                 "message_count": 12, "last_message_at": 1751500000.5, "pinned": true,
                 "some_future_field": {"nested": true}},
                {"session_id": "cron_nightly", "title": "Nightly job", "session_source": "cron"}
             ],
             "cli_count": 2, "server_time": 1751500001.0, "server_tz": "UTC"}
        """.trimIndent()

        val decoded = ApiJson.decodeFromString<SessionsResponse>(payload)
        val sessions = decoded.sessions.orEmpty()

        assertEquals(2, sessions.size)
        assertEquals("Fix the build", sessions[0].title)
        assertEquals(true, sessions[0].pinned)
        assertEquals(12, sessions[0].messageCount)
        assertTrue(sessions[1].isCronSession)
        assertEquals(2, decoded.cliCount)
    }

    @Test
    fun `session detail decodes messages with string and parts content`() {
        val payload = """
            {"session": {
                "session_id": "abc", "title": "T",
                "messages": [
                    {"role": "user", "content": "hello", "_ts": 1751500000.0},
                    {"role": "assistant",
                     "content": [{"type": "text", "text": "hi "}, {"type": "text", "text": "there"}],
                     "message_id": "m2"},
                    {"role": "assistant", "content": null, "reasoning": "thinking..."},
                    "not-an-object-at-all"
                ]
            }}
        """.trimIndent()

        val detail = ApiJson.decodeFromString<SessionResponse>(payload).session!!
        val messages = detail.chatMessages(ApiJson)

        // The malformed fourth element is dropped, not fatal.
        assertEquals(3, messages.size)
        assertEquals("hello", messages[0].textContent)
        assertEquals(1751500000.0, messages[0].effectiveTimestamp!!, 0.0001)
        assertEquals("hi there", messages[1].textContent)
        assertNull(messages[2].textContent)
        assertEquals("thinking...", messages[2].reasoning)
    }

    @Test
    fun `lenient decoding tolerates numbers sent as strings`() {
        val payload = """{"sessions": [{"session_id": "s", "message_count": "7"}]}"""
        val decoded = ApiJson.decodeFromString<SessionsResponse>(payload)
        assertEquals(7, decoded.sessions!![0].messageCount)
    }

    @Test
    fun `explicit nulls coerce to defaults instead of failing`() {
        val payload = """{"sessions": [{"session_id": "s", "title": null, "pinned": null}]}"""
        val decoded = ApiJson.decodeFromString<SessionsResponse>(payload)
        assertNull(decoded.sessions!![0].title)
        assertNull(decoded.sessions!![0].pinned)
    }

    @Test
    fun `session summary stable id falls back when session_id is missing`() {
        val summary = SessionSummary(title = " Untitled thing ", createdAt = 5.0)
        assertEquals("session-Untitled thing-5.0", summary.stableId)
    }
}
