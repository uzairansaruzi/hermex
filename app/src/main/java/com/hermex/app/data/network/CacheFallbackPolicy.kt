package com.hermex.app.data.network

import java.io.IOException

/**
 * Determines whether a failed API call should fall back to locally cached data.
 *
 * Mirrors iOS's `CacheFallbackPolicy`:
 * - **Allow cache:** IOException / ApiException.Network (connectivity, timeout,
 *   DNS) and transient HTTP errors (408, 502, 503, 504).
 * - **Never cache:** 401/Unauthorized (must route to auth), other 4xx (client
 *   errors — cache would hide real problems), 5xx not in the transient set.
 *
 * Extracted as a pure object so it can be unit-tested without ViewModel context.
 */
object CacheFallbackPolicy {

    private val TRANSIENT_HTTP_CODES = setOf(408, 502, 503, 504)

    /**
     * Returns `true` if the error is transient and cached data should be served.
     */
    fun shouldUseCache(error: Throwable): Boolean {
        return when (error) {
            is IOException -> true
            is ApiException.Network -> true
            is ApiException.Http -> error.code in TRANSIENT_HTTP_CODES
            is ApiException.Unauthorized -> false
            is ApiException.Decoding -> false
            else -> {
                // Legacy fallback: check message substrings for wrapped network errors
                // that predate the typed ApiException hierarchy.
                val msg = error.message ?: return false
                msg.contains("Unable to resolve host", ignoreCase = true) ||
                    msg.contains("timeout", ignoreCase = true)
            }
        }
    }
}
