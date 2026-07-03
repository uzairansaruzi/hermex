package com.hermex.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hermex.app.data.model.ChatStartRequest
import com.hermex.app.data.model.SSEEvent
import com.hermex.app.data.network.ApiClient
import com.hermex.app.data.network.SseClient
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class BackendE2ETest {
    @Test
    fun loginCreateChatStreamAndCleanupAgainstHermesBackend() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val serverUrl = args.getString("serverUrl")?.trimEnd('/').orEmpty()
        val password = args.getString("password").orEmpty()
        assumeTrue("Instrumentation arguments serverUrl and password are required", serverUrl.isNotBlank() && password.isNotBlank())

        val cookieJar = InMemoryCookieJar()
        val okHttp = OkHttpClient.Builder()
            .cookieJar(cookieJar)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
        val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
            encodeDefaults = true
        }
        val apiClient = ApiClient(okHttp, json).also { it.configure(serverUrl) }
        val sseClient = SseClient(okHttp, json)

        assertEquals("ok", apiClient.health().status)
        val login = apiClient.login(password)
        assertTrue("Login failed: ${login.error}", login.ok != false)
        assertTrue("Login did not persist any cookies", cookieJar.cookieCount() > 0)
        apiClient.sessions()

        val sessionResponse = apiClient.sessionNew()
        val sessionId = sessionResponse.session?.sessionId
        assertNotNull("sessionNew did not return a session id", sessionId)

        try {
            val chatStart = apiClient.chatStart(
                ChatStartRequest(
                    sessionId = sessionId!!,
                    message = "Android production readiness instrumentation test. Reply exactly: hermex-android-e2e-ok"
                )
            )
            val streamId = chatStart.streamId
            assertFalse("chatStart did not return a stream id", streamId.isNullOrBlank())

            var tokenCharacters = 0
            var terminalEventSeen = false
            try {
                withTimeout(90_000) {
                    sseClient.stream(apiClient.streamUrl(streamId!!)).collect { event ->
                        when (event) {
                            is SSEEvent.Token -> tokenCharacters += event.text.length
                            is SSEEvent.Done,
                            is SSEEvent.StreamEnd,
                            is SSEEvent.Cancelled -> {
                                terminalEventSeen = true
                                throw TerminalEventSeen()
                            }
                            is SSEEvent.Error -> throw AssertionError("SSE error: ${event.message}")
                            else -> Unit
                        }
                    }
                }
            } catch (_: TerminalEventSeen) {
                // Expected control flow once the stream reaches a terminal event.
            } catch (e: TimeoutCancellationException) {
                throw AssertionError("Timed out waiting for SSE terminal event", e)
            }
            assertTrue("SSE stream did not reach done/stream_end/cancel", terminalEventSeen)
            assertTrue("SSE stream returned no token content", tokenCharacters > 0)
        } finally {
            sessionId?.let { apiClient.sessionDelete(it) }
        }
    }

    private class TerminalEventSeen : RuntimeException()

    private class InMemoryCookieJar : CookieJar {
        private val store = mutableMapOf<String, List<Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            store[url.host] = cookies
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            return store[url.host].orEmpty()
        }

        fun cookieCount(): Int = store.values.sumOf { it.size }
    }
}
