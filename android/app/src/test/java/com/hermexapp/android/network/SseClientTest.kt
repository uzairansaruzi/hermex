package com.hermexapp.android.network

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** End-to-end SSE wire test: okhttp-sse parsing a real event-stream body. */
class SseClientTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `a chat stream delivers tokens, tools, and stream_end in order`() {
        val body = buildString {
            append("event: token\ndata: {\"text\": \"Hel\"}\n\n")
            append("event: token\ndata: {\"text\": \"lo\"}\n\n")
            append("event: tool\ndata: {\"name\": \"bash\", \"tid\": \"t1\"}\n\n")
            append("event: tool_complete\ndata: {\"name\": \"bash\", \"tid\": \"t1\", \"duration\": 0.5}\n\n")
            append("event: stream_end\ndata: {}\n\n")
        }
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "text/event-stream")
                .setBody(body),
        )

        val received = mutableListOf<SseEvent>()
        val finished = CountDownLatch(1)
        val client = SseClient(OkHttpClient())

        client.start(server.url("/api/chat/stream?stream_id=s1")) { event ->
            synchronized(received) { received.add(event) }
            if (event == SseEvent.StreamEnd) finished.countDown()
        }

        assertTrue("stream did not finish in time", finished.await(10, TimeUnit.SECONDS))
        client.stop()

        val events = synchronized(received) { received.toList() }
        assertEquals(SseEvent.Token("Hel"), events[0])
        assertEquals(SseEvent.Token("lo"), events[1])
        assertTrue(events[2] is SseEvent.ToolStarted)
        assertTrue(events[3] is SseEvent.ToolCompleted)
        assertEquals(SseEvent.StreamEnd, events[4])
    }

    @Test
    fun `a failed connection surfaces a transport error`() {
        server.enqueue(MockResponse().setResponseCode(503))

        val received = mutableListOf<SseEvent>()
        val failed = CountDownLatch(1)
        val client = SseClient(OkHttpClient())

        client.start(server.url("/api/chat/stream?stream_id=s1")) { event ->
            synchronized(received) { received.add(event) }
            if (event is SseEvent.TransportError) failed.countDown()
        }

        assertTrue("no transport error arrived", failed.await(10, TimeUnit.SECONDS))
        client.stop()
    }
}
