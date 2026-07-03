package com.hermexapp.android.features.sessionlist

import com.hermexapp.android.auth.InMemorySecretStore
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.SessionCookieJar
import com.hermexapp.android.persistence.InMemoryCacheStore
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class SessionRepositoryTest {

    private lateinit var server: MockWebServer
    private lateinit var repository: SessionRepository
    private val cache = InMemoryCacheStore()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val client = ApiClient(
            baseUrl = server.url("/"),
            httpClient = OkHttpClient.Builder()
                .cookieJar(SessionCookieJar(InMemorySecretStore()))
                .build(),
        )
        repository = SessionRepository(client, cache)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `sessions are sorted pinned-first then by recency`() = runBlocking {
        server.enqueue(
            json(
                """
                {"sessions": [
                    {"session_id": "old", "last_message_at": 100.0},
                    {"session_id": "pinned-old", "last_message_at": 50.0, "pinned": true},
                    {"session_id": "new", "last_message_at": 200.0}
                ]}
                """,
            ),
        )

        val result = repository.loadSessions()

        assertFalse(result.fromCache)
        assertEquals(listOf("pinned-old", "new", "old"), result.sessions.map { it.sessionId })
    }

    @Test
    fun `a network failure falls back to the cached list`() = runBlocking {
        server.enqueue(json("""{"sessions": [{"session_id": "cached-one"}]}"""))
        repository.loadSessions()

        server.shutdown()
        val result = repository.loadSessions()

        assertTrue(result.fromCache)
        assertEquals("cached-one", result.sessions.single().sessionId)
    }

    @Test
    fun `a network failure with no cache rethrows`(): Unit = runBlocking {
        server.shutdown()
        try {
            repository.loadSessions()
            fail("Expected ApiError.Network")
        } catch (e: ApiError) {
            assertTrue(e is ApiError.Network)
        }
    }

    @Test
    fun `a 401 surfaces even when a cache exists`(): Unit = runBlocking {
        server.enqueue(json("""{"sessions": [{"session_id": "cached-one"}]}"""))
        repository.loadSessions()

        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"Authentication required"}"""))
        try {
            repository.loadSessions()
            fail("Expected ApiError.Unauthorized")
        } catch (e: ApiError) {
            assertTrue(e is ApiError.Unauthorized)
        }
    }

    @Test
    fun `session detail is cached for offline reopening`() = runBlocking {
        server.enqueue(
            json(
                """
                {"session": {"session_id": "abc", "title": "T",
                             "messages": [{"role": "user", "content": "hi"}]}}
                """,
            ),
        )
        val (fresh, freshFromCache) = repository.loadSession("abc")
        assertFalse(freshFromCache)
        assertEquals("T", fresh?.title)

        server.shutdown()
        val (cached, cachedFromCache) = repository.loadSession("abc")
        assertTrue(cachedFromCache)
        assertEquals("T", cached?.title)
        assertEquals(1, cached?.messages?.size)
    }

    private fun json(body: String): MockResponse =
        MockResponse()
            .setResponseCode(200)
            .setHeader("Content-Type", "application/json")
            .setBody(body.trimIndent())
}
