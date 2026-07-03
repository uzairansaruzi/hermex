package com.hermexapp.android.network

import com.hermexapp.android.auth.InMemorySecretStore
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** Paths, query names, and body keys mirror the iOS Endpoint enum exactly. */
class ApiClientSessionsChatTest {

    private lateinit var server: MockWebServer
    private lateinit var client: ApiClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = ApiClient(
            baseUrl = server.url("/"),
            httpClient = OkHttpClient.Builder()
                .cookieJar(SessionCookieJar(InMemorySecretStore()))
                .build(),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `sessions list and search hit the right paths`() = runBlocking {
        server.enqueue(json("""{"sessions": []}"""))
        client.sessions()
        assertEquals("/api/sessions", server.takeRequest().path)

        server.enqueue(json("""{"sessions": [], "query": "x", "count": 0}"""))
        client.searchSessions("build fix")
        assertEquals(
            "/api/sessions/search?q=build%20fix&content=1&depth=5",
            server.takeRequest().path,
        )
    }

    @Test
    fun `session detail passes id, messages flag, and message limit`() = runBlocking {
        server.enqueue(json("""{"session": {"session_id": "abc"}}"""))
        client.session("abc")
        assertEquals(
            "/api/session?session_id=abc&messages=1&msg_limit=50",
            server.takeRequest().path,
        )
    }

    @Test
    fun `createSession posts snake_case fields and omits nulls`() = runBlocking {
        server.enqueue(json("""{"session": {"session_id": "new"}}"""))
        client.createSession(model = "gpt-x", modelProvider = "openai")

        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/session/new", request.path)
        assertEquals("""{"model":"gpt-x","model_provider":"openai"}""", request.body.readUtf8())
    }

    @Test
    fun `startChat posts the message with session_id`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1", "session_id": "abc"}"""))
        val response = client.startChat(sessionId = "abc", message = "hello")

        assertEquals("st1", response.streamId)
        val request = server.takeRequest()
        assertEquals("/api/chat/start", request.path)
        assertEquals("""{"session_id":"abc","message":"hello"}""", request.body.readUtf8())
    }

    @Test
    fun `cancel and steer follow the iOS shapes`() = runBlocking {
        server.enqueue(json("""{"ok": true, "cancelled": true}"""))
        client.cancelChat("st1")
        assertEquals("/api/chat/cancel?stream_id=st1", server.takeRequest().path)

        server.enqueue(json("""{"ok": true}"""))
        client.steerChat("abc", "focus on tests")
        val steer = server.takeRequest()
        assertEquals("/api/chat/steer", steer.path)
        assertEquals("""{"session_id":"abc","text":"focus on tests"}""", steer.body.readUtf8())
    }

    @Test
    fun `chatStreamUrl carries the stream id`() {
        assertEquals(
            server.url("/api/chat/stream?stream_id=st1"),
            client.chatStreamUrl("st1"),
        )
    }

    private fun json(body: String): MockResponse =
        MockResponse()
            .setResponseCode(200)
            .setHeader("Content-Type", "application/json")
            .setBody(body)
}
