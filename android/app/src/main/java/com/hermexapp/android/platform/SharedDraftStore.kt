package com.hermexapp.android.platform

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Phase 9 share target: text (or an image URI) shared into the app (ACTION_SEND)
 * parks here until the connected UI consumes it into a new chat — the Android
 * counterpart of the iOS `SharedDraftStore` bridging the share extension.
 * In-memory only; a share into a signed-out app is simply dropped after
 * onboarding (a durable handoff can come with the share-extension parity slice).
 */
class SharedDraftStore {

    data class SharedContent(val text: String?, val fileUris: List<String> = emptyList()) {
        val isEmpty: Boolean get() = text.isNullOrBlank() && fileUris.isEmpty()
    }

    private val _pending = MutableStateFlow<SharedContent?>(null)
    val pending: StateFlow<SharedContent?> = _pending

    fun offer(text: String?, fileUris: List<String> = emptyList()) {
        val content = SharedContent(text?.trim()?.takeIf { it.isNotEmpty() }, fileUris)
        if (!content.isEmpty) _pending.value = content
    }

    /** Returns and clears the pending share. */
    fun consume(): SharedContent? = _pending.value.also { _pending.value = null }
}
