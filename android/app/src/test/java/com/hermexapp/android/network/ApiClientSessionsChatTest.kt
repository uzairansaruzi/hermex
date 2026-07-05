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
    fun `duplicate move and branch follow the pinned upstream shapes`() = runBlocking {
        server.enqueue(json("""{"session": {"session_id": "copy1"}}"""))
        val dup = client.duplicateSession("abc")
        val dupReq = server.takeRequest()
        assertEquals("/api/session/duplicate", dupReq.path)
        assertEquals("""{"session_id":"abc"}""", dupReq.body.readUtf8())
        assertEquals("copy1", dup.session?.sessionId)

        server.enqueue(json("""{"ok": true, "session": {"session_id": "abc"}}"""))
        client.moveSession("abc", "proj9")
        val moveReq = server.takeRequest()
        assertEquals("/api/session/move", moveReq.path)
        assertEquals("""{"session_id":"abc","project_id":"proj9"}""", moveReq.body.readUtf8())

        // A null project (un-file) omits project_id thanks to explicitNulls=false.
        server.enqueue(json("""{"ok": true}"""))
        client.moveSession("abc", null)
        assertEquals("""{"session_id":"abc"}""", server.takeRequest().body.readUtf8())

        server.enqueue(json("""{"session_id": "fork1", "title": "X (fork)", "parent_session_id": "abc"}"""))
        val branch = client.branchSession("abc")
        val branchReq = server.takeRequest()
        assertEquals("/api/session/branch", branchReq.path)
        assertEquals("""{"session_id":"abc"}""", branchReq.body.readUtf8())
        assertEquals("fork1", branch.sessionId)
    }

    @Test
    fun `project CRUD hits the right paths and decodes`() = runBlocking {
        server.enqueue(json("""{"projects": [{"project_id": "p1", "name": "Work", "color": "#FF3B30"}]}"""))
        val list = client.projects()
        assertEquals("/api/projects", server.takeRequest().path)
        assertEquals("Work", list.projects?.first()?.name)

        server.enqueue(json("""{"ok": true, "project": {"project_id": "p2", "name": "New"}}"""))
        client.createProject("New", "#34C759")
        val createReq = server.takeRequest()
        assertEquals("/api/projects/create", createReq.path)
        assertEquals("""{"name":"New","color":"#34C759"}""", createReq.body.readUtf8())

        server.enqueue(json("""{"ok": true, "project": {"project_id": "p2", "name": "Renamed"}}"""))
        client.renameProject("p2", "Renamed", null)
        val renameReq = server.takeRequest()
        assertEquals("/api/projects/rename", renameReq.path)
        assertEquals("""{"project_id":"p2","name":"Renamed"}""", renameReq.body.readUtf8())

        server.enqueue(json("""{"ok": true}"""))
        client.deleteProject("p2")
        val deleteReq = server.takeRequest()
        assertEquals("/api/projects/delete", deleteReq.path)
        assertEquals("""{"project_id":"p2"}""", deleteReq.body.readUtf8())
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
