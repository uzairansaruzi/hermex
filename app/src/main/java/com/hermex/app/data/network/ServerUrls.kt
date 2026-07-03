package com.hermex.app.data.network

/**
 * Pure URL-normalization helpers for Hermes server addresses.
 * Extracted so both [ApiClient.configure] and [OnboardingViewModel]
 * share the same logic, and so it can be unit-tested without Android.
 */

/**
 * Normalizes a user-entered server URL:
 * - Trims whitespace and trailing slashes.
 * - Defaults bare hosts (no scheme) to `https://` so that public tunnel
 *   endpoints aren't rejected by [LocalCleartextInterceptor].
 * - Preserves an explicit `http://` or `https://` scheme.
 */
fun normalizeServerUrl(input: String): String {
    val trimmed = input.trim().trimEnd('/')
    return if (
        trimmed.startsWith("http://", ignoreCase = true) ||
        trimmed.startsWith("https://", ignoreCase = true)
    ) {
        trimmed
    } else {
        "https://$trimmed"
    }
}

/**
 * Returns an HTTP fallback URL for an HTTPS (or bare-host) address, or
 * `null` when the input is already plain HTTP (no further fallback).
 *
 * Used by the onboarding flow to try TLS first and fall back to cleartext
 * for private-network/loopback Hermes servers.
 */
fun httpFallbackUrl(url: String): String? {
    val trimmed = url.trim()
    return when {
        trimmed.startsWith("https://", ignoreCase = true) ->
            "http://" + trimmed.substringAfter("://")
        // Bare hosts are configured as HTTPS by default.  Fall back to
        // explicit http:// so local/private LAN servers still connect via
        // LocalCleartextInterceptor's allowlist.
        !trimmed.startsWith("http://", ignoreCase = true) ->
            "http://$trimmed"
        else -> null
    }
}
