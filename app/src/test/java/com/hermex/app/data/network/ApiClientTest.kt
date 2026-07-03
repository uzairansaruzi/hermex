package com.hermex.app.data.network

import com.hermex.app.data.model.ChatMessage
import com.hermex.app.data.model.SessionDetail
import com.hermex.app.data.model.SessionResponse
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ApiClientTest {
    @Test
    fun configureBareHostDefaultsToHttps() {
        val client = ApiClient(
            okHttpClient = OkHttpClient(),
            json = Json { ignoreUnknownKeys = true }
        )

        client.configure("192.168.0.157:8787/")

        assertEquals("https://192.168.0.157:8787", client.baseUrl)
    }

    @Test
    fun configurePreservesExplicitHttpsScheme() {
        val client = ApiClient(
            okHttpClient = OkHttpClient(),
            json = Json { ignoreUnknownKeys = true }
        )

        client.configure("https://hermes.example.com/")

        assertEquals("https://hermes.example.com", client.baseUrl)
    }

    @Test
    fun configurePreservesExplicitHttpScheme() {
        val client = ApiClient(
            okHttpClient = OkHttpClient(),
            json = Json { ignoreUnknownKeys = true }
        )

        client.configure("http://192.168.1.100:5000")

        assertEquals("http://192.168.1.100:5000", client.baseUrl)
    }

    @Test
    fun localCleartextPolicyAllowsOnlyLocalOrPrivateNetworkHosts() {
        assertEquals(true, isLocalCleartextHost("127.0.0.1"))
        assertEquals(true, isLocalCleartextHost("10.0.2.2"))
        assertEquals(true, isLocalCleartextHost("192.168.0.157"))
        assertEquals(false, isLocalCleartextHost("example.com"))
    }
}

// ---------------------------------------------------------------------------
// Session / message deserialization
// ---------------------------------------------------------------------------

class SessionDeserializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun sessionDecodesUnderscoreMessagesOffset() {
        // Server sends "_messages_offset", not "messages_offset"
        val payload = """{"session":{"session_id":"s1","_messages_offset":42,"messages":[]}}"""
        val response = json.decodeFromString<SessionResponse>(payload)
        assertEquals(42, response.session?.messagesOffset)
    }

    @Test
    fun sessionDecodesPlainMessagesOffset() {
        // Fallback: "messages_offset" (without leading underscore)
        val payload = """{"session":{"session_id":"s1","messages_offset":10,"messages":[]}}"""
        val response = json.decodeFromString<SessionResponse>(payload)
        assertEquals(10, response.session?.messagesOffset)
    }

    @Test
    fun sessionDecodesNullMessagesOffset() {
        val payload = """{"session":{"session_id":"s1","messages":[]}}"""
        val response = json.decodeFromString<SessionResponse>(payload)
        assertNull(response.session?.messagesOffset)
    }
}

class ChatMessageTimestampTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun tsDecodesNumericValue() {
        val payload = """{"role":"user","content":"hi","_ts":1770000000.5}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertEquals(1770000000.5, message.ts!!, 0.001)
    }

    @Test
    fun tsDecodesStringValue() {
        // Server sometimes sends _ts as a quoted string
        val payload = """{"role":"user","content":"hi","_ts":"1770000000.5"}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertEquals(1770000000.5, message.ts!!, 0.001)
    }

    @Test
    fun tsDecodesNullValue() {
        val payload = """{"role":"user","content":"hi","_ts":null}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertNull(message.ts)
    }

    @Test
    fun tsDecodesAbsentField() {
        val payload = """{"role":"user","content":"hi"}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertNull(message.ts)
    }

    @Test
    fun effectiveTimestampPrefersTsOverTimestamp() {
        val payload = """{"role":"user","content":"hi","_ts":200.0,"timestamp":100.0}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertEquals(200.0, message.effectiveTimestamp, 0.001)
    }

    @Test
    fun effectiveTimestampFallsBackToTimestamp() {
        val payload = """{"role":"user","content":"hi","timestamp":100.0}"""
        val message = json.decodeFromString<ChatMessage>(payload)
        assertEquals(100.0, message.effectiveTimestamp, 0.001)
    }
}

class ServerUrlsTest {
    @Test
    fun normalizeServerUrlDefaultsBareHostToHttps() {
        assertEquals("https://hermes.example.com", normalizeServerUrl("hermes.example.com"))
    }

    @Test
    fun normalizeServerUrlDefaultsBareHostAndPortToHttps() {
        assertEquals("https://192.168.0.157:8787", normalizeServerUrl("192.168.0.157:8787/"))
    }

    @Test
    fun normalizeServerUrlPreservesExplicitHttp() {
        assertEquals("http://192.168.1.100:5000", normalizeServerUrl("http://192.168.1.100:5000"))
    }

    @Test
    fun normalizeServerUrlPreservesExplicitHttps() {
        assertEquals("https://hermes.example.com", normalizeServerUrl("https://hermes.example.com/"))
    }

    @Test
    fun normalizeServerUrlTrimsWhitespace() {
        assertEquals("https://hermes.example.com", normalizeServerUrl("  hermes.example.com  "))
    }

    @Test
    fun httpFallbackUrlFromHttpsReturnsHttp() {
        assertEquals("http://hermes.example.com", httpFallbackUrl("https://hermes.example.com"))
    }

    @Test
    fun httpFallbackUrlFromBareHostReturnsHttp() {
        assertEquals("http://192.168.1.100:5000", httpFallbackUrl("192.168.1.100:5000"))
    }

    @Test
    fun httpFallbackUrlFromHttpReturnsNull() {
        assertNull(httpFallbackUrl("http://192.168.1.100:5000"))
    }

    // G4 fix: edge cases identified in audit dimension E1
    @Test
    fun normalizeServerUrlBracketsIpv6Literal() {
        assertEquals("https://[::1]", normalizeServerUrl("::1"))
    }

    @Test
    fun normalizeServerUrlBracketsFullIpv6() {
        // Zone ID is preserved as-is (URI encoding happens downstream in OkHttp).
        assertEquals("https://[fe80::1%eth0]", normalizeServerUrl("fe80::1%eth0"))
    }

    @Test
    fun normalizeServerUrlPreservesExistingBracketedIpv6() {
        assertEquals("http://[::1]:8080", normalizeServerUrl("http://[::1]:8080"))
    }

    @Test
    fun normalizeServerUrlHandlesSubpathDeployment() {
        assertEquals("https://myserver.com/hermes", normalizeServerUrl("myserver.com/hermes/"))
    }

    @Test
    fun normalizeServerUrlHandlesUppercaseScheme() {
        assertEquals("HTTPS://myserver.com", normalizeServerUrl("HTTPS://myserver.com/"))
    }
}
