package com.hermex.app.data.network

import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.kotlin.whenever
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class HermesAuthenticatorTest {

    private lateinit var server: MockWebServer
    private lateinit var authManager: com.hermex.app.data.auth.AuthManager
    private lateinit var cookieJar: TestCookieJar
    private lateinit var json: Json

    @Before
    fun setUp() {
        server = MockWebServer()
        authManager = mock()
        cookieJar = TestCookieJar()
        json = Json { ignoreUnknownKeys = true }
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun buildClient(): OkHttpClient {
        val authenticator = HermesAuthenticator(authManager, cookieJar, json)
        return OkHttpClient.Builder()
            .authenticator(authenticator)
            .cookieJar(cookieJar)
            .build()
    }

    // -------------------------------------------------------------------------
    // Test A: single 401 → login → retry succeeds
    // -------------------------------------------------------------------------
    @Test
    fun single401TriggersLoginAndRetriesOriginalRequest() {
        whenever(authManager.getPassword()).thenReturn("secret")

        val loginCount = AtomicInteger(0)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    loginCount.incrementAndGet()
                    return MockResponse()
                        .setResponseCode(200)
                        .setBody("""{"ok":true}""")
                        .addHeader("Set-Cookie", "session=fresh; Path=/")
                        .addHeader("Content-Type", "application/json")
                }
                // First request to /api/sessions returns 401; retry succeeds.
                val cookies = request.getHeader("Cookie")
                return if (cookies != null && cookies.contains("session=fresh")) {
                    MockResponse()
                        .setResponseCode(200)
                        .setBody("""{"sessions":[]}""")
                        .addHeader("Content-Type", "application/json")
                } else {
                    MockResponse().setResponseCode(401)
                }
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(200, response.code)
        assertEquals(1, loginCount.get())
        verify(authManager).markLoggedIn()
    }

    // -------------------------------------------------------------------------
    // Test B: concurrent 401s → exactly ONE login request
    // -------------------------------------------------------------------------
    @Test
    fun concurrent401sResultInSingleLoginRequest() {
        whenever(authManager.getPassword()).thenReturn("secret")

        val loginCount = AtomicInteger(0)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    loginCount.incrementAndGet()
                    return MockResponse()
                        .setResponseCode(200)
                        .setBody("""{"ok":true}""")
                        .addHeader("Set-Cookie", "session=fresh; Path=/")
                        .addHeader("Content-Type", "application/json")
                }
                val cookies = request.getHeader("Cookie")
                return if (cookies != null && cookies.contains("session=fresh")) {
                    MockResponse()
                        .setResponseCode(200)
                        .setBody("""{"ok":true}""")
                        .addHeader("Content-Type", "application/json")
                } else {
                    MockResponse().setResponseCode(401)
                }
            }
        }
        server.start()

        val client = buildClient()
        val threads = 3
        val startLatch = CountDownLatch(1)
        val doneLatch = CountDownLatch(threads)
        val results = ConcurrentHashMap<Int, Int>()

        repeat(threads) { i ->
            Thread {
                startLatch.await()
                val resp = client.newCall(
                    Request.Builder().url(server.url("/api/data/$i")).build()
                ).execute()
                results[i] = resp.code
                doneLatch.countDown()
            }.start()
        }

        startLatch.countDown()
        doneLatch.await(30, TimeUnit.SECONDS)

        // All requests should succeed.
        results.forEach { (idx, code) ->
            assertEquals("Request $idx failed", 200, code)
        }
        // Only one login should have been made.
        assertEquals("Expected exactly 1 login request", 1, loginCount.get())
    }

    // -------------------------------------------------------------------------
    // Test C: login returns 500 → null, no markLoggedOut
    // -------------------------------------------------------------------------
    @Test
    fun loginServerErrorDoesNotChangeAuthState() {
        whenever(authManager.getPassword()).thenReturn("secret")

        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    return MockResponse()
                        .setResponseCode(500)
                        .setBody("Internal Server Error")
                }
                return MockResponse().setResponseCode(401)
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(401, response.code)
        verify(authManager, never()).markLoggedOut()
        verify(authManager, never()).markLoggedIn()
    }

    // -------------------------------------------------------------------------
    // Test D: login socket failure → null, no state change
    // -------------------------------------------------------------------------
    @Test
    fun loginNetworkFailureDoesNotChangeAuthState() {
        whenever(authManager.getPassword()).thenReturn("secret")

        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    return MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START)
                }
                return MockResponse().setResponseCode(401)
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(401, response.code)
        verify(authManager, never()).markLoggedOut()
        verify(authManager, never()).markLoggedIn()
    }

    // -------------------------------------------------------------------------
    // Test E: login returns {"ok":false} → markLoggedOut
    // -------------------------------------------------------------------------
    @Test
    fun loginBadPasswordMarksLoggedOut() {
        whenever(authManager.getPassword()).thenReturn("wrong")

        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    return MockResponse()
                        .setResponseCode(200)
                        .setBody("""{"ok":false,"error":"Invalid password"}""")
                        .addHeader("Content-Type", "application/json")
                }
                return MockResponse().setResponseCode(401)
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(401, response.code)
        verify(authManager).markLoggedOut()
    }

    // -------------------------------------------------------------------------
    // Test F: login returns 401 → markLoggedOut
    // -------------------------------------------------------------------------
    @Test
    fun login401MarksLoggedOut() {
        whenever(authManager.getPassword()).thenReturn("secret")

        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                if (path.startsWith("/api/auth/login")) {
                    return MockResponse()
                        .setResponseCode(401)
                        .setBody("""{"ok":false}""")
                        .addHeader("Content-Type", "application/json")
                }
                return MockResponse().setResponseCode(401)
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(401, response.code)
        verify(authManager).markLoggedOut()
    }

    // -------------------------------------------------------------------------
    // Test G: no password saved → markLoggedOut, no login attempt
    // -------------------------------------------------------------------------
    @Test
    fun noSavedPasswordMarksLoggedOutWithoutLogin() {
        whenever(authManager.getPassword()).thenReturn(null)

        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                return MockResponse().setResponseCode(401)
            }
        }
        server.start()

        val client = buildClient()
        val response = client.newCall(
            Request.Builder().url(server.url("/api/sessions")).build()
        ).execute()

        assertEquals(401, response.code)
        verify(authManager).markLoggedOut()
        // No login request should have been made.
        assertEquals(1, server.requestCount) // only the initial 401
    }

    /**
     * Simple thread-safe CookieJar that merges cookies by name (per host).
     */
    private class TestCookieJar : CookieJar {
        private val store = ConcurrentHashMap<String, MutableMap<String, Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            val hostMap = store.getOrPut(url.host) { ConcurrentHashMap() }
            for (cookie in cookies) {
                hostMap[cookie.name] = cookie
            }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            return store[url.host]?.values?.toList().orEmpty()
        }
    }
}
