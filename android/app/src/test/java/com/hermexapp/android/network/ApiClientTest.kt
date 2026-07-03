package com.hermexapp.android.network

import com.hermexapp.android.auth.InMemorySecretStore
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * MockWebServer harness for the networking core — the Android counterpart of
 * the iOS URLProtocol-based mock server. Response payloads mirror the pinned
 * upstream handlers in `api/routes.py` / `api/auth.py` (hard rule #1).
 */
class ApiClientTest {

    private lateinit var server: MockWebServer
    private lateinit var cookieJar: SessionCookieJar
    private lateinit var client: ApiClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        cookieJar = SessionCookieJar(InMemorySecretStore())
        client = ApiClient(
            baseUrl = server.url("/"),
            httpClient = OkHttpClient.Builder().cookieJar(cookieJar).build(),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `health decodes the upstream payload and ignores unknown fields`() = runBlocking {
        // Shape from upstream _handle_health (api/routes.py).
        server.enqueue(
            json(
                """
                {"status": "ok", "sessions": 3, "active_streams": 1, "active_runs": 0,
                 "runs": [], "last_run_finished_at": null, "uptime_seconds": 42.5,
                 "accept_loop": {"status": "ok"}}
                """,
            ),
        )

        val health = client.health()

        assertEquals("ok", health.status)
        assertEquals(3, health.sessions)
        assertEquals(1, health.activeStreams)
        assertEquals(42.5, health.uptimeSeconds!!, 0.0001)
        assertEquals("/health", server.takeRequest().path)
    }

    @Test
    fun `authStatus decodes auth_enabled and logged_in`() = runBlocking {
        // Shape from the /api/auth/status handler (api/routes.py).
        server.enqueue(json("""{"auth_enabled": true, "logged_in": false}"""))

        val status = client.authStatus()

        assertEquals(true, status.authEnabled)
        assertEquals(false, status.loggedIn)
        assertNull(status.passwordAuthEnabled)
        assertEquals("/api/auth/status", server.takeRequest().path)
    }

    @Test
    fun `login posts the password as JSON and stores the session cookie`() = runBlocking {
        // Success shape + cookie from the /api/auth/login handler and
        // set_auth_cookie (api/auth.py, COOKIE_NAME = hermes_session).
        server.enqueue(
            json("""{"ok": true}""")
                .addHeader(
                    "Set-Cookie",
                    "hermes_session=token.sig; HttpOnly; Path=/; SameSite=Lax; Max-Age=2592000",
                ),
        )
        server.enqueue(json("""{"auth_enabled": true, "logged_in": true}"""))

        val login = client.login("hunter2")
        assertEquals(true, login.ok)

        val loginRequest = server.takeRequest()
        assertEquals("POST", loginRequest.method)
        assertEquals("/api/auth/login", loginRequest.path)
        assertTrue(loginRequest.getHeader("Content-Type")!!.startsWith("application/json"))
        assertEquals("""{"password":"hunter2"}""", loginRequest.body.readUtf8())

        // The next request must replay the cookie — same behaviour the server's
        // check_auth relies on.
        client.authStatus()
        val followUp = server.takeRequest()
        assertEquals("hermes_session=token.sig", followUp.getHeader("Cookie"))
    }

    @Test
    fun `401 maps to Unauthorized`() = runBlocking {
        // check_auth's unauthenticated API response (api/auth.py).
        server.enqueue(
            MockResponse().setResponseCode(401).setBody("""{"error":"Authentication required"}"""),
        )

        try {
            client.authStatus()
            fail("Expected ApiError.Unauthorized")
        } catch (e: ApiError) {
            assertTrue(e is ApiError.Unauthorized)
        }
    }

    @Test
    fun `non-2xx maps to Http with the body preserved`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(503).setBody("""{"status":"degraded"}"""))

        try {
            client.health()
            fail("Expected ApiError.Http")
        } catch (e: ApiError) {
            val http = e as ApiError.Http
            assertEquals(503, http.statusCode)
            assertEquals("""{"status":"degraded"}""", http.body)
        }
    }

    @Test
    fun `malformed JSON maps to Decoding`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("<html>not json</html>"))

        try {
            client.health()
            fail("Expected ApiError.Decoding")
        } catch (e: ApiError) {
            assertTrue(e is ApiError.Decoding)
        }
    }

    @Test
    fun `building a client for cleartext to a public host is refused`() {
        try {
            ApiClient("http://hermes.example.com/".toHttpUrl(), OkHttpClient())
            fail("Expected ApiError.CleartextNotAllowed")
        } catch (e: ApiError) {
            assertEquals("hermes.example.com", (e as ApiError.CleartextNotAllowed).host)
        }
    }

    private fun json(body: String): MockResponse =
        MockResponse()
            .setResponseCode(200)
            .setHeader("Content-Type", "application/json")
            .setBody(body.trimIndent())
}
