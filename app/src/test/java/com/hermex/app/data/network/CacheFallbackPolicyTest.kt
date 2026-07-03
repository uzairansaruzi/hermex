package com.hermex.app.data.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

class CacheFallbackPolicyTest {

    // -------------------------------------------------------------------------
    // Network errors → should use cache
    // -------------------------------------------------------------------------

    @Test
    fun ioExceptionAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(IOException("Connection reset")))
    }

    @Test
    fun socketTimeoutAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(SocketTimeoutException("Read timed out")))
    }

    @Test
    fun unknownHostAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(UnknownHostException("Unable to resolve host")))
    }

    @Test
    fun apiExceptionNetworkAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(
            ApiException.Network(IOException("Connection refused"))
        ))
    }

    // -------------------------------------------------------------------------
    // Transient HTTP errors → should use cache
    // -------------------------------------------------------------------------

    @Test
    fun http408AllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(ApiException.Http(408, "Request Timeout")))
    }

    @Test
    fun http502AllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(ApiException.Http(502, "Bad Gateway")))
    }

    @Test
    fun http503AllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(ApiException.Http(503, "Service Unavailable")))
    }

    @Test
    fun http504AllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(ApiException.Http(504, "Gateway Timeout")))
    }

    // -------------------------------------------------------------------------
    // Non-transient errors → never use cache
    // -------------------------------------------------------------------------

    @Test
    fun http401NeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(ApiException.Unauthorized(401, "Unauthorized")))
    }

    @Test
    fun http403NeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(ApiException.Http(403, "Forbidden")))
    }

    @Test
    fun http404NeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(ApiException.Http(404, "Not Found")))
    }

    @Test
    fun http500NeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(ApiException.Http(500, "Internal Server Error")))
    }

    @Test
    fun decodingErrorNeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(
            ApiException.Decoding(RuntimeException("Bad JSON"))
        ))
    }

    @Test
    fun genericExceptionNeverAllowsCache() {
        assertFalse(CacheFallbackPolicy.shouldUseCache(RuntimeException("Something unexpected")))
    }

    // -------------------------------------------------------------------------
    // Legacy fallback: message-based matching for pre-typed exceptions
    // -------------------------------------------------------------------------

    @Test
    fun legacyUnableToResolveHostAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(
            RuntimeException("Unable to resolve host example.com")
        ))
    }

    @Test
    fun legacyTimeoutMessageAllowsCache() {
        assertTrue(CacheFallbackPolicy.shouldUseCache(
            RuntimeException("Connection timeout exceeded")
        ))
    }
}
