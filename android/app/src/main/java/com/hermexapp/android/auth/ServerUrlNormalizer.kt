package com.hermexapp.android.auth

import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.CleartextPolicy
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Mirrors the iOS `AuthManager.normalizedServerURL(from:)` rules exactly:
 * trim; default the scheme (https, except plain-HTTP-eligible hosts —
 * localhost/loopback and the Tailscale CGNAT range — which default to http);
 * strip any path/query/fragment; rewrite a `www.webui.<host>` prefix to
 * `webui.<host>`. Plus the Android-specific gate: an explicit http:// URL to a
 * host outside the cleartext allowlist is rejected here, in the connection
 * layer, since the platform config cannot express the CIDR rule (plan §2).
 */
object ServerUrlNormalizer {

    fun normalize(rawValue: String): HttpUrl {
        val trimmed = rawValue.trim()
        if (trimmed.isEmpty()) throw ApiError.InvalidServerUrl

        val withScheme = if ("://" in trimmed) trimmed else "${defaultScheme(trimmed)}://$trimmed"
        if (!withScheme.startsWith("http://") && !withScheme.startsWith("https://")) {
            throw ApiError.InvalidServerUrl
        }

        val parsed = withScheme.toHttpUrlOrNull() ?: throw ApiError.InvalidServerUrl

        val host = normalizedHost(parsed.host)
        val normalized = parsed.newBuilder()
            .host(host)
            .encodedPath("/")
            .query(null)
            .fragment(null)
            .build()

        if (normalized.scheme == "http" && !CleartextPolicy.allowsCleartext(normalized.host)) {
            throw ApiError.CleartextNotAllowed(normalized.host)
        }

        return normalized
    }

    private fun normalizedHost(host: String): String {
        val lowercased = host.lowercase()
        return if (lowercased.startsWith("www.webui.")) host.substring(4) else host
    }

    private fun defaultScheme(rawValue: String): String {
        val host = "http://$rawValue".toHttpUrlOrNull()?.host?.lowercase()
            ?: return "https"
        return if (CleartextPolicy.allowsCleartext(host)) "http" else "https"
    }
}
