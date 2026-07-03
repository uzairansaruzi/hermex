package com.hermex.app.data.network

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
