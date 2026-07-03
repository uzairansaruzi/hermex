package com.hermexapp.android.features.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermexapp.android.features.sessionlist.SessionRepository
import com.hermexapp.android.model.ChatMessage
import com.hermexapp.android.model.SessionDetail
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.ApiJson
import com.hermexapp.android.network.SseEvent
import com.hermexapp.android.network.SseStreaming
import com.hermexapp.android.network.cancelChat
import com.hermexapp.android.network.chatStreamUrl
import com.hermexapp.android.network.startChat
import com.hermexapp.android.network.steerChat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Phase 4 chat state machine: transcript load, send → `/api/chat/start` →
 * SSE stream, token/reasoning/tool events into a timeline, steer-while-
 * running, and stop via `/api/chat/cancel`. Rendering is plain text for now —
 * streaming markdown is the plan's flagged risk and lands as its own slice.
 *
 * SSE events arrive on OkHttp's reader thread; every mutation goes through
 * `MutableStateFlow.update`, which is atomic, so no main-thread hop is needed.
 */
class ChatViewModel(
    private val sessionId: String,
    private val repository: SessionRepository,
    private val client: ApiClient,
    private val sse: SseStreaming,
    private val onAuthError: (Throwable) -> Unit = {},
) : ViewModel() {

    sealed class TimelineEntry {
        abstract val id: String

        data class UserMessage(override val id: String, val text: String) : TimelineEntry()

        data class AssistantMessage(
            override val id: String,
            val text: String,
            val isStreaming: Boolean = false,
        ) : TimelineEntry()

        data class Reasoning(
            override val id: String,
            val text: String,
            val isStreaming: Boolean = false,
        ) : TimelineEntry()

        data class ToolCall(
            override val id: String,
            val name: String?,
            val preview: String?,
            val isRunning: Boolean,
            val isError: Boolean = false,
            val durationSeconds: Double? = null,
        ) : TimelineEntry()

        data class Notice(override val id: String, val text: String) : TimelineEntry()
    }

    data class UiState(
        val title: String? = null,
        val entries: List<TimelineEntry> = emptyList(),
        val composerText: String = "",
        val isLoading: Boolean = false,
        val isStreaming: Boolean = false,
        val isFromCache: Boolean = false,
        val errorMessage: String? = null,
    )

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private var activeStreamId: String? = null
    private var entryCounter = 0

    private fun nextId(prefix: String): String = "$prefix-${entryCounter++}"

    fun updateComposerText(value: String) = _uiState.update { it.copy(composerText = value) }

    fun load() {
        viewModelScope.launch { loadNow() }
    }

    fun send() {
        viewModelScope.launch { sendNow() }
    }

    fun stop() {
        viewModelScope.launch { stopNow() }
    }

    suspend fun loadNow() {
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        try {
            val (detail, fromCache) = repository.loadSession(sessionId)
            _uiState.update {
                it.copy(
                    title = detail?.title,
                    entries = entriesFromDetail(detail),
                    isFromCache = fromCache,
                    isLoading = false,
                )
            }
        } catch (e: ApiError) {
            onAuthError(e)
            _uiState.update { it.copy(errorMessage = e.userMessage, isLoading = false) }
        }
    }

    suspend fun sendNow() {
        val text = _uiState.value.composerText.trim()
        if (text.isEmpty()) return

        if (_uiState.value.isStreaming) {
            steerNow(text)
            return
        }

        _uiState.update {
            it.copy(
                composerText = "",
                errorMessage = null,
                entries = it.entries + TimelineEntry.UserMessage(nextId("user"), text),
            )
        }

        try {
            val response = client.startChat(sessionId = sessionId, message = text)
            val streamId = response.streamId
            if (streamId.isNullOrEmpty()) {
                _uiState.update {
                    it.copy(errorMessage = response.error ?: "The server did not start a run.")
                }
                return
            }
            activeStreamId = streamId
            _uiState.update { it.copy(isStreaming = true) }
            sse.start(client.chatStreamUrl(streamId), ::onSseEvent)
        } catch (e: ApiError) {
            onAuthError(e)
            _uiState.update { it.copy(errorMessage = e.userMessage) }
        }
    }

    /** Mid-run message → `/api/chat/steer`, like the iOS composer while streaming. */
    suspend fun steerNow(text: String) {
        _uiState.update {
            it.copy(
                composerText = "",
                entries = it.entries + TimelineEntry.UserMessage(nextId("steer"), text),
            )
        }
        try {
            client.steerChat(sessionId, text)
        } catch (e: ApiError) {
            onAuthError(e)
            _uiState.update { it.copy(errorMessage = e.userMessage) }
        }
    }

    suspend fun stopNow() {
        val streamId = activeStreamId ?: return
        try {
            client.cancelChat(streamId)
            // The stream delivers `cancel` + `stream_end`, which finish the state.
        } catch (e: ApiError) {
            onAuthError(e)
            // Server unreachable — end the run locally rather than hang.
            sse.stop()
            finishStreaming()
            _uiState.update { it.copy(errorMessage = e.userMessage) }
        }
    }

    /** Stops the SSE stream when the screen goes away. */
    fun teardown() = sse.stop()

    // ── SSE event application (called on OkHttp's reader thread) ──

    internal fun onSseEvent(event: SseEvent) {
        when (event) {
            is SseEvent.Token -> appendToDraft(event.text)
            is SseEvent.Reasoning -> appendToReasoning(event.text)
            is SseEvent.InterimAssistant -> applyInterim(event)
            is SseEvent.ToolStarted -> upsertTool(event.tool, running = true)
            is SseEvent.ToolCompleted -> upsertTool(event.tool, running = false)
            is SseEvent.Title -> _uiState.update { it.copy(title = event.title ?: it.title) }
            is SseEvent.Done -> applyDone(event)
            is SseEvent.PendingSteerLeftover ->
                _uiState.update { it.copy(composerText = event.text) }
            SseEvent.StreamEnd -> {
                sse.stop()
                finishStreaming()
            }
            SseEvent.Cancelled -> _uiState.update {
                it.copy(entries = it.entries + TimelineEntry.Notice(nextId("notice"), "Run stopped."))
            }
            is SseEvent.Error -> failStream(event.message)
            is SseEvent.TransportError ->
                if (_uiState.value.isStreaming) failStream(event.message) else Unit
            SseEvent.Ignored -> Unit
        }
    }

    private fun appendToDraft(text: String) {
        if (text.isEmpty()) return
        _uiState.update { state ->
            val entries = state.entries.toMutableList()
            val last = entries.lastOrNull()
            if (last is TimelineEntry.AssistantMessage && last.isStreaming) {
                entries[entries.lastIndex] = last.copy(text = last.text + text)
            } else {
                entries += TimelineEntry.AssistantMessage(nextId("assistant"), text, isStreaming = true)
            }
            state.copy(entries = entries)
        }
    }

    private fun appendToReasoning(text: String) {
        if (text.isEmpty()) return
        _uiState.update { state ->
            val entries = state.entries.toMutableList()
            val last = entries.lastOrNull()
            if (last is TimelineEntry.Reasoning && last.isStreaming) {
                entries[entries.lastIndex] = last.copy(text = last.text + text)
            } else {
                entries += TimelineEntry.Reasoning(nextId("reasoning"), text, isStreaming = true)
            }
            state.copy(entries = entries)
        }
    }

    /**
     * An interim assistant message closes out the current turn segment
     * (typically between tool calls). `already_streamed == true` means its text
     * is the draft we already accumulated — just finalize; otherwise it's a
     * complete message we haven't seen — append it whole.
     */
    private fun applyInterim(event: SseEvent.InterimAssistant) {
        _uiState.update { state ->
            var entries = finalizeDrafts(state.entries)
            if (event.alreadyStreamed != true && !event.text.isNullOrBlank()) {
                entries = entries + TimelineEntry.AssistantMessage(nextId("assistant"), event.text)
            }
            state.copy(entries = entries)
        }
    }

    private fun upsertTool(tool: com.hermexapp.android.network.ToolStreamEvent, running: Boolean) {
        _uiState.update { state ->
            val entries = state.entries.toMutableList()
            val key = tool.stableId
            val index = entries.indexOfLast { entry ->
                entry is TimelineEntry.ToolCall && when {
                    key != null -> entry.id == "tool-$key"
                    else -> entry.isRunning && entry.name == tool.name
                }
            }

            val updated = TimelineEntry.ToolCall(
                id = if (key != null) "tool-$key" else nextId("tool"),
                name = tool.name,
                preview = tool.preview,
                isRunning = running,
                isError = tool.isError == true,
                durationSeconds = tool.duration,
            )

            if (index >= 0) {
                val existing = entries[index] as TimelineEntry.ToolCall
                entries[index] = updated.copy(
                    id = existing.id,
                    name = tool.name ?: existing.name,
                    preview = tool.preview ?: existing.preview,
                )
            } else {
                entries += updated
            }
            state.copy(entries = entries)
        }
    }

    /** `done` carries the authoritative session — rebuild the transcript from it. */
    private fun applyDone(event: SseEvent.Done) {
        val session = event.session?.let {
            try {
                ApiJson.decodeFromJsonElement(SessionDetail.serializer(), it)
            } catch (_: Exception) {
                null
            }
        } ?: return

        _uiState.update {
            it.copy(title = session.title ?: it.title, entries = entriesFromDetail(session))
        }
    }

    private fun failStream(message: String) {
        sse.stop()
        finishStreaming()
        _uiState.update { it.copy(errorMessage = message) }
    }

    private fun finishStreaming() {
        activeStreamId = null
        _uiState.update { state ->
            state.copy(isStreaming = false, entries = finalizeDrafts(state.entries))
        }
    }

    private fun finalizeDrafts(entries: List<TimelineEntry>): List<TimelineEntry> =
        entries.map { entry ->
            when {
                entry is TimelineEntry.AssistantMessage && entry.isStreaming ->
                    entry.copy(isStreaming = false)
                entry is TimelineEntry.Reasoning && entry.isStreaming ->
                    entry.copy(isStreaming = false)
                else -> entry
            }
        }

    private fun entriesFromDetail(detail: SessionDetail?): List<TimelineEntry> {
        val messages = detail?.chatMessages(ApiJson) ?: return emptyList()
        return messages.mapIndexedNotNull { index, message -> entryFromMessage(message, index) }
    }

    private fun entryFromMessage(message: ChatMessage, index: Int): TimelineEntry? {
        val text = message.textContent
        return when (message.role) {
            "user" ->
                // Tool-result rows are user-role with no visible text — skip them.
                if (!text.isNullOrBlank()) {
                    TimelineEntry.UserMessage("history-$index-${message.stableId}", text)
                } else {
                    null
                }
            "assistant" ->
                if (!text.isNullOrBlank()) {
                    TimelineEntry.AssistantMessage("history-$index-${message.stableId}", text)
                } else if (!message.reasoning.isNullOrBlank()) {
                    TimelineEntry.Reasoning("history-$index-${message.stableId}", message.reasoning)
                } else {
                    null
                }
            else -> null
        }
    }
}
