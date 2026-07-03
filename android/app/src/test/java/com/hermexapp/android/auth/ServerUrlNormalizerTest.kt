package com.hermexapp.android.auth

import com.hermexapp.android.network.ApiError
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** Mirrors the iOS `normalizedServerURL` rules — see AuthManager.swift. */
class ServerUrlNormalizerTest {

    @Test
    fun `a bare hostname defaults to https`() {
        assertEquals("https://hermes.example.com/", ServerUrlNormalizer.normalize("hermes.example.com").toString())
    }

    @Test
    fun `whitespace is trimmed and path query fragment are stripped`() {
        assertEquals(
            "https://hermes.example.com/",
            ServerUrlNormalizer.normalize("  https://hermes.example.com/dashboard?tab=1#top  ").toString(),
        )
    }

    @Test
    fun `localhost and loopback default to plain http`() {
        assertEquals("http://localhost:8787/", ServerUrlNormalizer.normalize("localhost:8787").toString())
        assertEquals("http://127.0.0.1:8787/", ServerUrlNormalizer.normalize("127.0.0.1:8787").toString())
        assertEquals("http://10.0.2.2:8787/", ServerUrlNormalizer.normalize("10.0.2.2:8787").toString())
    }

    @Test
    fun `tailscale CGNAT addresses default to plain http`() {
        assertEquals("http://100.101.102.103:8787/", ServerUrlNormalizer.normalize("100.101.102.103:8787").toString())
    }

    @Test
    fun `a www webui host prefix is collapsed`() {
        assertEquals("https://webui.example.com/", ServerUrlNormalizer.normalize("www.webui.example.com").toString())
    }

    @Test
    fun `explicit http to a public host is rejected with the cleartext error`() {
        try {
            ServerUrlNormalizer.normalize("http://hermes.example.com")
            fail("Expected CleartextNotAllowed")
        } catch (e: ApiError.CleartextNotAllowed) {
            assertEquals("hermes.example.com", e.host)
        }
    }

    @Test
    fun `explicit http to a tailscale address is allowed`() {
        assertEquals("http://100.64.0.1:8787/", ServerUrlNormalizer.normalize("http://100.64.0.1:8787").toString())
    }

    @Test
    fun `empty and unparseable input is rejected`() {
        for (input in listOf("", "   ", "ftp://example.com", "http://")) {
            try {
                ServerUrlNormalizer.normalize(input)
                fail("Expected InvalidServerUrl for '$input'")
            } catch (_: ApiError.InvalidServerUrl) {
                // expected
            } catch (_: ApiError.CleartextNotAllowed) {
                fail("Expected InvalidServerUrl for '$input', got CleartextNotAllowed")
            }
        }
    }
}
