package com.hermex.app.ui.navigation

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/** Host-based deep-link parser mirroring the iOS HermesDeepLink contract. */
object HermesDeepLink {
    const val SCHEME = "hermes-agent"
    private const val SESSION_HOST = "session"
    private const val NEW_CHAT_HOST = "new-chat"
    private const val NEW_CHAT_VOICE_HOST = "new-chat-voice"
    private const val NEW_CHAT_PROFILE_HOST = "new-chat-profile"
    private const val PROFILE_QUERY_ITEM = "profile"

    fun newChatUrl(): String = "$SCHEME://$NEW_CHAT_HOST"
    fun newChatVoiceUrl(): String = "$SCHEME://$NEW_CHAT_VOICE_HOST"
    fun newChatInProfileUrl(profileName: String): String? {
        val trimmed = profileName.trim()
        if (trimmed.isEmpty()) return null
        return "$SCHEME://$NEW_CHAT_PROFILE_HOST?$PROFILE_QUERY_ITEM=${encode(trimmed)}"
    }

    fun sessionUrl(sessionId: String): String? {
        val trimmed = sessionId.trim()
        if (trimmed.isEmpty()) return null
        return "$SCHEME://$SESSION_HOST?id=${encode(trimmed)}"
    }

    fun isNewChatUrl(url: String): Boolean = parse(url)?.let { uri ->
        uri.scheme?.lowercase(Locale.ROOT) == SCHEME && uri.host?.lowercase(Locale.ROOT) == NEW_CHAT_HOST
    } ?: false

    fun isNewChatVoiceUrl(url: String): Boolean = parse(url)?.let { uri ->
        uri.scheme?.lowercase(Locale.ROOT) == SCHEME && uri.host?.lowercase(Locale.ROOT) == NEW_CHAT_VOICE_HOST
    } ?: false

    fun isNewChatInProfileUrl(url: String): Boolean = parse(url)?.let { uri ->
        uri.scheme?.lowercase(Locale.ROOT) == SCHEME && uri.host?.lowercase(Locale.ROOT) == NEW_CHAT_PROFILE_HOST
    } ?: false

    fun profileNameFromNewChatInProfile(url: String): String? {
        if (!isNewChatInProfileUrl(url)) return null
        val raw = queryParameter(url, PROFILE_QUERY_ITEM)?.trim().orEmpty()
        return raw.takeIf { it.isNotEmpty() }
    }

    fun sessionId(url: String): String? {
        val uri = parse(url) ?: return null
        if (uri.scheme?.lowercase(Locale.ROOT) != SCHEME || uri.host?.lowercase(Locale.ROOT) != SESSION_HOST) return null
        val queryId = queryParameter(url, "id") ?: queryParameter(url, "session_id")
        if (!queryId.isNullOrBlank()) return queryId.trim()
        return uri.path
            ?.split('/')
            ?.firstOrNull { it.isNotBlank() }
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun parse(url: String): URI? = runCatching { URI(url) }.getOrNull()

    private fun queryParameter(url: String, name: String): String? {
        val rawQuery = parse(url)?.rawQuery ?: return null
        return rawQuery.split('&')
            .mapNotNull { pair ->
                val idx = pair.indexOf('=')
                if (idx < 0) null else pair.substring(0, idx) to pair.substring(idx + 1)
            }
            .firstOrNull { (key, _) -> decode(key) == name }
            ?.second
            ?.let(::decode)
    }

    private fun encode(value: String): String = java.net.URLEncoder.encode(value, StandardCharsets.UTF_8.name())
    private fun decode(value: String): String = URLDecoder.decode(value, StandardCharsets.UTF_8.name())
}
