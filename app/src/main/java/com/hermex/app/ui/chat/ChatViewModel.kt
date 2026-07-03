package com.hermex.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.model.*
import com.hermex.app.data.network.ApiClient
import com.hermex.app.data.network.SseClient
import com.hermex.app.ui.notifications.HermexNotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.HttpUrl
import java.util.*
import javax.inject.Inject

/**
 * Display model for a single message row in the transcript.
 */
data class TranscriptMessage(
    val loadedIndex: Int,
    val fullHistoryIndex: Int,
    val keepCountThroughMessage: Int,
    val renderId: String,
    val anchorId: String,
    val message: ChatMessage
)

data class ReasoningGroup(
    val id: String = UUID.randomUUID().toString(),
    val anchorMessageId: String? = null,
    val text: String
)

data class ToolCallDisplay(
    val id: String = UUID.randomUUID().toString(),
    val anchorMessageId: String? = null,
    val toolCall: ToolStreamEvent,
    val isCompleted: Boolean = false
)

/**
 * Context passed to message long-press action callbacks.
 */
sealed class MessageActionContext(
    val role: Role,
    val visibleIndex: Int,
    val fullHistoryIndex: Int,
    val keepCountThroughMessage: Int,
    val messageId: String,
    val copyText: String
) {
    enum class Role { User, Assistant }

    class UserContext(
        visibleIndex: Int,
        fullHistoryIndex: Int,
        keepCountThroughMessage: Int,
        messageId: String,
        copyText: String
    ) : MessageActionContext(Role.User, visibleIndex, fullHistoryIndex, keepCountThroughMessage, messageId, copyText)

    class AssistantContext(
        visibleIndex: Int,
        fullHistoryIndex: Int,
        keepCountThroughMessage: Int,
        messageId: String,
        copyText: String
    ) : MessageActionContext(Role.Assistant, visibleIndex, fullHistoryIndex, keepCountThroughMessage, messageId, copyText)
}

/**
 * UI state exposed by [ChatViewModel].
 */
data class ChatUiState(
    val title: String = "",
    val messages: List<ChatMessage> = emptyList(),
    val messageOffset: Int = 0,
    val displayedTranscriptMessages: List<TranscriptMessage> = emptyList(),
    val isLoading: Boolean = false,
    val isStartingChat: Boolean = false,
    val isCancellingStream: Boolean = false,
    val isEditingMessage: Boolean = false,
    val isForkingMessage: Boolean = false,
    val isRegeneratingMessage: Boolean = false,
    val errorMessage: String? = null,
    val sendErrorMessage: String? = null,
    val messageActionErrorMessage: String? = null,
    val composerErrorMessage: String? = null,
    val currentModel: String? = null,
    val currentModelProvider: String? = null,
    val currentWorkspace: String? = null,
    val currentProfile: String? = null,
    val selectedProfileName: String? = null,
    val availableModels: Map<String, List<String>> = emptyMap(),
    val availableProfiles: List<ProfileInfo> = emptyList(),
    val availableWorkspaces: List<String> = emptyList(),
    val isLoadingComposerConfig: Boolean = false,
    val isUpdatingComposerConfig: Boolean = false,
    val contextWindowSnapshot: UsageSnapshot? = null,
    val streamingAssistantMessageId: String? = null,
    val liveReasoningText: String = "",
    val liveToolCalls: List<ToolStreamEvent> = emptyList(),
    val completedReasoningGroups: List<ReasoningGroup> = emptyList(),
    val completedToolCallGroups: List<ToolCallDisplay> = emptyList(),
    val activeStreamId: String? = null,
    val approvalPending: ApprovalPendingResponse? = null,
    val clarificationPending: ClarificationPendingResponse? = null,
    val isRespondingToPendingAction: Boolean = false,
    val pendingActionErrorMessage: String? = null,
    val isListening: Boolean = false,
    val listeningMessageId: String? = null
)

@HiltViewModel
class ChatViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val appContext: Context,
    private val apiClient: ApiClient,
    private val sseClient: SseClient,
    private val notificationManager: HermexNotificationManager,
    private val messageDao: com.hermex.app.data.persistence.MessageDao
) : ViewModel() {

    private val sessionId: String = savedStateHandle.get<String>("sessionId")
        ?: throw IllegalArgumentException("ChatViewModel requires a sessionId argument")

    private val _uiState = MutableStateFlow(ChatUiState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private var currentStreamId: String? = null
    private var streamingJob: Job? = null
    // A3 fix: generation counter prevents a stale handleStreamError coroutine
    // from resurrecting a stream the user already cancelled.
    private var streamGeneration = 0L
    // A4 fix: prevents double notification/reload when Done + late Error
    // both try to finalize the same response.
    private var hasFinalized = false

    private var pendingAssistantTokenChunks = mutableListOf<String>()
    private var pendingReasoningChunks = mutableListOf<String>()
    private var pendingStreamingContentFlushJob: Job? = null
    private var pendingScrollTriggerJob: Job? = null
    private var isReplayingConnection = false

    private val _scrollToBottomEvent = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val scrollToBottomEvent: SharedFlow<Unit> = _scrollToBottomEvent.asSharedFlow()

    private var textToSpeech: TextToSpeech? = null
    private var ttsInitialized = false

    private val compressionAnchorMetadata: CompressionAnchorMetadata? = null

    init {
        textToSpeech = TextToSpeech(appContext) { status ->
            ttsInitialized = status == TextToSpeech.SUCCESS
            if (ttsInitialized) {
                textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = Unit

                    override fun onDone(utteranceId: String?) {
                        clearListeningState(utteranceId)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        clearListeningState(utteranceId)
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        clearListeningState(utteranceId)
                    }
                })
            }
        }
        loadMessages()
        loadComposerConfiguration()
    }

    override fun onCleared() {
        super.onCleared()
        // A6 fix: do NOT call stopStreaming() — the server-side run should
        // continue after the user navigates away (matching iOS).  Only the
        // explicit Stop button sends /api/chat/cancel.  Cancel only the
        // local SSE subscription and clean up resources.
        streamingJob?.cancel()
        currentStreamId = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
    }

    // -------------------------------------------------------------------------
    // Loading
    // -------------------------------------------------------------------------

    fun loadMessages() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            try {
                val response = apiClient.session(sessionId, messages = true, msgLimit = 50)
                val session = response.session
                val loadedMessages = session?.messages ?: emptyList()
                val messageOffset = session?.messagesOffset ?: 0
                val title = session?.title?.takeIf { it.isNotBlank() } ?: "Untitled Session"

                _uiState.update { state ->
                    state.copy(
                        isLoading = false,
                        messages = loadedMessages,
                        messageOffset = messageOffset,
                        title = title,
                        currentModel = session?.model ?: state.currentModel,
                        currentModelProvider = session?.modelProvider ?: state.currentModelProvider,
                        currentWorkspace = session?.workspace ?: state.currentWorkspace,
                        currentProfile = session?.profile ?: state.currentProfile,
                        contextWindowSnapshot = UsageSnapshot(
                            inputTokens = session?.inputTokens,
                            outputTokens = session?.outputTokens,
                            estimatedCost = session?.estimatedCost,
                            contextLength = session?.contextLength
                        ),
                        displayedTranscriptMessages = buildTranscriptMessages(loadedMessages, null, messageOffset),
                        errorMessage = null
                    )
                }
                emitScrollToBottom()

                // F3: cache messages for offline fallback
                cacheMessages(loadedMessages)
            } catch (e: Exception) {
                // F3: on transient failures, serve cached messages instead of
                // showing a blank error screen (matches iOS CacheFallbackPolicy).
                if (com.hermex.app.data.network.CacheFallbackPolicy.shouldUseCache(e)) {
                    serveCachedMessagesOrError(e)
                } else {
                    _uiState.update { it.copy(isLoading = false, errorMessage = e.message ?: "Failed to load messages") }
                }
            }
        }
    }

    /** Cache messages locally for offline fallback. */
    private suspend fun cacheMessages(messages: List<ChatMessage>) {
        try {
            messageDao.clearSession(sessionId)
            messageDao.insertMessages(messages.mapNotNull { msg ->
                val id = msg.messageId ?: return@mapNotNull null
                com.hermex.app.data.persistence.CachedMessage(
                    messageId = id,
                    sessionId = sessionId,
                    role = msg.role,
                    content = msg.content,
                    timestamp = msg.timestamp,
                    name = msg.name,
                    reasoning = msg.reasoning
                )
            })
        } catch (_: Exception) {
            // Cache failure is non-fatal — proceed without caching.
        }
    }

    /** Attempt to load messages from Room; show error if cache is also empty. */
    private suspend fun serveCachedMessagesOrError(originalError: Exception) {
        try {
            val cachedList = messageDao.getMessages(sessionId).first()
            if (cachedList.isNotEmpty()) {
                val loadedMessages = cachedList.map { cached ->
                    ChatMessage(
                        role = cached.role,
                        content = cached.content,
                        timestamp = cached.timestamp,
                        messageId = cached.messageId,
                        name = cached.name,
                        reasoning = cached.reasoning
                    )
                }
                _uiState.update { state ->
                    state.copy(
                        isLoading = false,
                        messages = loadedMessages,
                        displayedTranscriptMessages = buildTranscriptMessages(loadedMessages, null, 0),
                        errorMessage = "Showing cached messages (offline)"
                    )
                }
                emitScrollToBottom()
                return
            }
        } catch (_: Exception) {
            // Cache read failed — fall through to show original error.
        }
        _uiState.update { it.copy(isLoading = false, errorMessage = originalError.message ?: "Failed to load messages") }
    }

    // -------------------------------------------------------------------------
    // Composer configuration
    // -------------------------------------------------------------------------

    fun loadComposerConfiguration() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingComposerConfig = true, composerErrorMessage = null) }
            try {
                val modelsResponse = async { apiClient.models() }
                val profilesResponse = async { apiClient.profiles() }
                val workspacesResponse = async { apiClient.workspaces() }

                val models = modelsResponse.await()
                val profiles = profilesResponse.await()
                val workspaces = workspacesResponse.await()

                _uiState.update { state ->
                    val activeProfile = profiles.activeProfile ?: state.currentProfile
                    state.copy(
                        isLoadingComposerConfig = false,
                        availableModels = models.modelsByProvider(),
                        availableProfiles = profiles.profiles ?: emptyList(),
                        availableWorkspaces = workspaces.workspaces.orEmpty()
                            .mapNotNull { it.path?.takeIf(String::isNotBlank) },
                        currentModel = state.currentModel ?: models.defaultModel,
                        currentProfile = state.currentProfile ?: activeProfile,
                        selectedProfileName = state.selectedProfileName ?: activeProfile
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoadingComposerConfig = false, composerErrorMessage = e.message) }
            }
        }
    }

    fun selectModel(model: String, provider: String?) {
        // Model selection is session-scoped: it only affects the model passed to
        // /api/chat/start for the current conversation.  Do NOT call
        // apiClient.defaultModel() here — that would change the server-wide
        // default, making a temporary chat selection affect future sessions and
        // the Settings screen unexpectedly.
        _uiState.update { state ->
            state.copy(
                currentModel = model,
                currentModelProvider = provider
            )
        }
    }

    fun selectWorkspace(workspace: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isUpdatingComposerConfig = true, composerErrorMessage = null) }
            try {
                _uiState.update { state ->
                    state.copy(
                        isUpdatingComposerConfig = false,
                        currentWorkspace = workspace
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isUpdatingComposerConfig = false, composerErrorMessage = e.message) }
            }
        }
    }

    fun selectProfile(profile: ProfileInfo) {
        viewModelScope.launch {
            _uiState.update { it.copy(isUpdatingComposerConfig = true, composerErrorMessage = null) }
            try {
                val name = profile.name?.takeIf { it.isNotBlank() } ?: return@launch
                apiClient.profileSwitch(name)
                loadComposerConfiguration()
                _uiState.update { state ->
                    state.copy(
                        isUpdatingComposerConfig = false,
                        selectedProfileName = name,
                        currentProfile = name
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isUpdatingComposerConfig = false, composerErrorMessage = e.message) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Sending / streaming
    // -------------------------------------------------------------------------

    fun sendMessage(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return

        viewModelScope.launch {
            val state = _uiState.value
            if (state.activeStreamId != null) return@launch

            _uiState.update {
                it.copy(
                    isStartingChat = true,
                    sendErrorMessage = null,
                    errorMessage = null,
                    composerErrorMessage = null
                )
            }

            resetStreamingBuffers()
            archiveLiveStreamingIfNeeded()

            val optimisticMessage = ChatMessage(
                role = "user",
                content = trimmed,
                timestamp = System.currentTimeMillis() / 1000.0,
                messageId = "local-${UUID.randomUUID()}"
            )

            val previousMessages = _uiState.value.messages
            _uiState.update { state ->
                state.copy(
                    messages = previousMessages + optimisticMessage,
                    displayedTranscriptMessages = buildTranscriptMessages(previousMessages + optimisticMessage, null, state.messageOffset)
                )
            }
            emitScrollToBottom()

            try {
                val response = apiClient.chatStart(
                    ChatStartRequest(
                        sessionId = sessionId,
                        message = trimmed,
                        workspace = _uiState.value.currentWorkspace,
                        model = _uiState.value.currentModel
                    )
                )

                val streamId = response.streamId
                if (streamId == null) {
                    _uiState.update {
                        it.copy(
                            isStartingChat = false,
                            sendErrorMessage = "The server did not return a stream ID."
                        )
                    }
                    return@launch
                }

                _uiState.update { it.copy(isStartingChat = false, activeStreamId = streamId) }
                startStream(streamId)
            } catch (e: Exception) {
                val messagesWithoutOptimistic = _uiState.value.messages.filter { it.messageId != optimisticMessage.messageId }
                _uiState.update {
                    it.copy(
                        isStartingChat = false,
                        sendErrorMessage = e.message ?: "Failed to send message",
                        messages = messagesWithoutOptimistic,
                        displayedTranscriptMessages = buildTranscriptMessages(messagesWithoutOptimistic, null, state.messageOffset)
                    )
                }
            }
        }
    }

    private fun startStream(streamId: String) {
        // Cancel only the local SSE subscription — do NOT call stopStreaming()
        // which sends /api/chat/cancel to the server.  During reattachment the
        // server stream is still running and must not be cancelled.
        streamingJob?.cancel()
        currentStreamId = streamId
        val myGeneration = ++streamGeneration   // A3: new generation
        hasFinalized = false                    // A4: allow finalization
        val url = apiClient.streamUrl(streamId)

        streamingJob = viewModelScope.launch {
            try {
                sseClient.stream(url).collect { event ->
                    when (event) {
                        is SSEEvent.Token -> appendToken(event.text)
                        is SSEEvent.Reasoning -> appendReasoning(event.text)
                        is SSEEvent.ToolStarted -> appendToolCall(event.event)
                        is SSEEvent.ToolCompleted -> completeToolCall(event.event)
                        is SSEEvent.Title -> updateTitle(event.title)
                        is SSEEvent.Done -> finalizeMessage(event.event.usage)
                        is SSEEvent.StreamEnd -> finishStream()
                        is SSEEvent.Cancelled -> finishStream()
                        is SSEEvent.Error -> {
                            handleStreamError(streamId, event.message)
                        }
                        is SSEEvent.ApprovalPending -> {
                            _uiState.update { it.copy(approvalPending = event.response) }
                            emitScrollToBottom()
                        }
                        is SSEEvent.ClarificationPending -> {
                            _uiState.update { it.copy(clarificationPending = event.response) }
                            emitScrollToBottom()
                        }
                        is SSEEvent.InterimAssistant -> appendInterimAssistant(event.event.content)
                        is SSEEvent.SteerLeftover -> {}
                    }
                }
            } catch (e: Exception) {
                handleStreamError(streamId, e.message ?: "Stream error")
            }
        }
    }

    /**
     * When the SSE connection drops (transient network change, Cloudflare idle
     * timeout, etc.), check whether the server-side stream is still active before
     * giving up.  If it is, reattach by reopening the SSE connection with replay
     * deduplication enabled.  Only finalize when the server confirms the stream
     * is no longer running.
     */
    private fun handleStreamError(streamId: String, errorMessage: String) {
        val myGeneration = streamGeneration  // A3: capture generation before async work
        viewModelScope.launch {
            try {
                val status = apiClient.chatStreamStatus(streamId)
                // A3: if the user stopped or a new stream started while we were
                // awaiting the status check, abandon this recovery path.
                if (streamGeneration != myGeneration) return@launch
                if (status.active == true) {
                    // Server stream is still running — reattach.
                    isReplayingConnection = true
                    startStream(streamId)
                    return@launch
                }
                if (status.done == true) {
                    // Server finished while SSE was disconnected.
                    // Reload the full transcript instead of showing an error.
                    finalizeMessage(null)
                    return@launch
                }
                // Server reports an error or unknown state — show it.
                val serverError = status.error
                if (serverError != null) {
                    _uiState.update { it.copy(sendErrorMessage = serverError) }
                } else {
                    _uiState.update { it.copy(sendErrorMessage = errorMessage) }
                }
            } catch (_: Exception) {
                if (streamGeneration != myGeneration) return@launch
                // Status check itself failed — show the original SSE error.
                _uiState.update { it.copy(sendErrorMessage = errorMessage) }
            }
            finishStream()
        }
    }

    private fun appendToken(token: String) {
        if (token.isEmpty()) return
        val streamingId = ensureStreamingAssistantMessage()
        val effectiveToken = if (isReplayingConnection) {
            val flushedContent = _uiState.value.messages.find { it.messageId == streamingId }?.content ?: ""
            val effectiveContent = flushedContent + pendingAssistantTokenChunks.joinToString("")
            val remainder = deduplicateToken(token, effectiveContent)
            if (remainder.isNotEmpty()) {
                isReplayingConnection = false
            }
            remainder
        } else {
            token
        }
        if (effectiveToken.isEmpty()) return
        pendingAssistantTokenChunks.add(effectiveToken)
        scheduleStreamingContentFlush()
    }

    private fun appendReasoning(text: String) {
        if (text.isEmpty()) return
        ensureStreamingAssistantMessage()
        pendingReasoningChunks.add(text)
        scheduleStreamingContentFlush()
    }

    private fun appendInterimAssistant(content: String?) {
        val text = content?.trim() ?: return
        if (text.isEmpty()) return
        flushPendingStreamingContent()
        val streamingId = _uiState.value.streamingAssistantMessageId
        if (streamingId != null) {
            val messages = _uiState.value.messages.toMutableList()
            val index = messages.indexOfFirst { it.messageId == streamingId }
            if (index >= 0) {
                val existing = messages[index]
                val separator = if (existing.content.isNullOrBlank()) "" else "\n\n"
                messages[index] = existing.copy(content = (existing.content ?: "") + separator + text)
                _uiState.update {
                    it.copy(
                        messages = messages,
                        displayedTranscriptMessages = buildTranscriptMessages(messages, streamingId, it.messageOffset)
                    )
                }
                emitScrollToBottom()
            }
        }
    }

    private fun appendToolCall(event: ToolStreamEvent) {
        val streamingId = ensureStreamingAssistantMessage()
        _uiState.update { state ->
            state.copy(
                liveToolCalls = state.liveToolCalls + event,
                streamingAssistantMessageId = streamingId
            )
        }
        emitScrollToBottom()
    }

    private fun completeToolCall(event: ToolStreamEvent) {
        val id = event.toolId ?: event.toolName
        _uiState.update { state ->
            val index = if (id != null) {
                state.liveToolCalls.indexOfLast { (it.toolId ?: it.toolName) == id }
            } else {
                state.liveToolCalls.indexOfLast { true }
            }
            if (index >= 0) {
                val updated = state.liveToolCalls.toMutableList()
                updated[index] = event
                state.copy(liveToolCalls = updated)
            } else {
                state.copy(liveToolCalls = state.liveToolCalls + event)
            }
        }
        emitScrollToBottom()
    }

    private fun updateTitle(title: String) {
        _uiState.update { it.copy(title = title.takeIf { it.isNotBlank() } ?: it.title) }
    }

    private fun finalizeMessage(usage: UsageSnapshot?) {
        // A4 fix: guard against double finalization (Done + late Error / status-done
        // racing can both reach this path for the same response).
        if (hasFinalized) return
        hasFinalized = true

        flushPendingStreamingContent()
        _uiState.update { state ->
            state.copy(
                contextWindowSnapshot = usage ?: state.contextWindowSnapshot,
                activeStreamId = null,
                streamingAssistantMessageId = null,
                liveReasoningText = "",
                liveToolCalls = emptyList()
            )
        }
        archiveLiveStreamingIfNeeded()
        notificationManager.notifyResponseComplete(sessionId, _uiState.value.title)
        loadMessages()
    }

    private fun finishStream() {
        flushPendingStreamingContent()
        streamingJob?.cancel()
        currentStreamId = null
        _uiState.update { state ->
            val messages = state.messages
            state.copy(
                activeStreamId = null,
                streamingAssistantMessageId = null,
                liveReasoningText = "",
                liveToolCalls = emptyList(),
                displayedTranscriptMessages = buildTranscriptMessages(messages, null, state.messageOffset)
            )
        }
    }

    fun stopStreaming() {
        val streamId = currentStreamId ?: return
        streamGeneration++  // A3: invalidate any in-flight handleStreamError
        viewModelScope.launch {
            _uiState.update { it.copy(isCancellingStream = true) }
            try {
                apiClient.chatCancel(streamId)
            } catch (_: Exception) {
            } finally {
                streamingJob?.cancel()
                currentStreamId = null
                _uiState.update {
                    it.copy(
                        isCancellingStream = false,
                        activeStreamId = null,
                        streamingAssistantMessageId = null,
                        liveReasoningText = "",
                        liveToolCalls = emptyList()
                    )
                }
            }
        }
    }

    fun clearTranscript() {
        resetStreamingBuffers()
        _uiState.update {
            it.copy(
                messages = emptyList(),
                displayedTranscriptMessages = emptyList(),
                liveReasoningText = "",
                liveToolCalls = emptyList(),
                completedReasoningGroups = emptyList(),
                completedToolCallGroups = emptyList(),
                errorMessage = null,
                sendErrorMessage = null,
                messageActionErrorMessage = null
            )
        }
    }

    fun appendLocalAssistantMessage(text: String) {
        val message = ChatMessage(
            role = "assistant",
            content = text,
            timestamp = System.currentTimeMillis() / 1000.0,
            messageId = "local-${UUID.randomUUID()}"
        )
        _uiState.update { state ->
            val updated = state.messages + message
            state.copy(
                messages = updated,
                displayedTranscriptMessages = buildTranscriptMessages(updated, state.streamingAssistantMessageId, state.messageOffset)
            )
        }
        emitScrollToBottom()
    }

    private fun ensureStreamingAssistantMessage(): String {
        val existing = _uiState.value.streamingAssistantMessageId
        if (existing != null) return existing

        val id = "stream-${UUID.randomUUID()}"
        val newMessage = ChatMessage(
            role = "assistant",
            content = "",
            timestamp = System.currentTimeMillis() / 1000.0,
            messageId = id
        )
        _uiState.update { state ->
            state.copy(
                messages = state.messages + newMessage,
                streamingAssistantMessageId = id,
                displayedTranscriptMessages = buildTranscriptMessages(state.messages + newMessage, id, state.messageOffset)
            )
        }
        emitScrollToBottom()
        return id
    }

    // -------------------------------------------------------------------------
    // Streaming buffer flush
    // -------------------------------------------------------------------------

    private fun scheduleStreamingContentFlush() {
        if (pendingStreamingContentFlushJob != null) return
        pendingStreamingContentFlushJob = viewModelScope.launch {
            delay(16)
            flushPendingStreamingContent()
        }
    }

    private fun flushPendingStreamingContent() {
        pendingStreamingContentFlushJob?.cancel()
        pendingStreamingContentFlushJob = null

        var didMutate = false
        if (flushAssistantTokens()) didMutate = true
        if (flushReasoningChunks()) didMutate = true

        if (didMutate) {
            emitScrollToBottom()
        }
    }

    private fun flushAssistantTokens(): Boolean {
        if (pendingAssistantTokenChunks.isEmpty()) return false
        val pendingText = pendingAssistantTokenChunks.joinToString("")
        pendingAssistantTokenChunks.clear()

        val streamingId = _uiState.value.streamingAssistantMessageId ?: return false
        val messages = _uiState.value.messages.toMutableList()
        val index = messages.indexOfFirst { it.messageId == streamingId }
        if (index < 0) return false

        val existing = messages[index]
        messages[index] = existing.copy(content = (existing.content ?: "") + pendingText)
        _uiState.update {
            it.copy(
                messages = messages,
                displayedTranscriptMessages = buildTranscriptMessages(messages, streamingId, it.messageOffset)
            )
        }
        return true
    }

    private fun flushReasoningChunks(): Boolean {
        if (pendingReasoningChunks.isEmpty()) return false
        val text = pendingReasoningChunks.joinToString("")
        pendingReasoningChunks.clear()

        _uiState.update { state ->
            state.copy(liveReasoningText = state.liveReasoningText + text)
        }
        return true
    }

    private fun resetStreamingBuffers() {
        pendingAssistantTokenChunks.clear()
        pendingReasoningChunks.clear()
        pendingStreamingContentFlushJob?.cancel()
        pendingStreamingContentFlushJob = null
        isReplayingConnection = false
    }

    private fun archiveLiveStreamingIfNeeded() {
        val state = _uiState.value
        val reasoning = state.liveReasoningText.trim()
        if (reasoning.isNotEmpty()) {
            val group = ReasoningGroup(
                anchorMessageId = state.streamingAssistantMessageId,
                text = reasoning
            )
            _uiState.update { it.copy(completedReasoningGroups = it.completedReasoningGroups + group) }
        }
        val tools = state.liveToolCalls
        if (tools.isNotEmpty()) {
            val groups = tools.map { ToolCallDisplay(anchorMessageId = state.streamingAssistantMessageId, toolCall = it, isCompleted = true) }
            _uiState.update { it.copy(completedToolCallGroups = it.completedToolCallGroups + groups) }
        }
    }

    private fun deduplicateToken(token: String, existingContent: String): String {
        if (existingContent.isEmpty()) return token
        if (existingContent.endsWith(token)) return ""
        if (token.startsWith(existingContent)) return token.substring(existingContent.length)

        val maxOverlap = minOf(existingContent.length, token.length)
        for (overlap in maxOverlap downTo 1) {
            if (existingContent.takeLast(overlap) == token.take(overlap)) {
                return token.substring(overlap)
            }
        }
        return token
    }

    // -------------------------------------------------------------------------
    // Message actions
    // -------------------------------------------------------------------------

    fun actionContextFor(message: ChatMessage, visibleIndex: Int): MessageActionContext? {
        val content = message.content ?: return null
        if (content.isBlank()) return null
        val fullHistoryIndex = _uiState.value.messageOffset + visibleIndex
        val keepCount = fullHistoryIndex + 1
        return when (message.role) {
            "user" -> MessageActionContext.UserContext(visibleIndex, fullHistoryIndex, keepCount, message.id, content)
            "assistant" -> MessageActionContext.AssistantContext(visibleIndex, fullHistoryIndex, keepCount, message.id, content)
            else -> null
        }
    }

    fun copyText(context: MessageActionContext) {
        val clipboard = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Message", context.copyText))
    }

    fun editMessage(context: MessageActionContext, newText: String) {
        val messages = _uiState.value.messages
        val index = messages.indexOfFirst { it.id == context.messageId }
        if (index < 0) return
        val edited = newText.trim()
        if (edited.isEmpty()) return

        viewModelScope.launch {
            _uiState.update { it.copy(isEditingMessage = true, messageActionErrorMessage = null) }
            try {
                val keepCount = context.keepCountThroughMessage - 1
                val truncateResponse = apiClient.sessionTruncate(sessionId, keepCount)
                val truncatedMessages = messages.take(index)

                _uiState.update { state ->
                    state.copy(
                        messages = truncatedMessages,
                        displayedTranscriptMessages = buildTranscriptMessages(truncatedMessages, null, state.messageOffset),
                        isEditingMessage = false
                    )
                }
                sendMessage(edited)
            } catch (e: Exception) {
                _uiState.update { it.copy(isEditingMessage = false, messageActionErrorMessage = e.message) }
            }
        }
    }

    fun forkFromMessage(context: MessageActionContext, onForked: (String) -> Unit) {
        viewModelScope.launch {
            _uiState.update { it.copy(isForkingMessage = true, messageActionErrorMessage = null) }
            try {
                val response = apiClient.sessionBranch(sessionId, context.keepCountThroughMessage, null)
                val forkedSessionId = response.session?.sessionId
                _uiState.update { it.copy(isForkingMessage = false) }
                if (forkedSessionId != null) {
                    onForked(forkedSessionId)
                } else {
                    _uiState.update { it.copy(messageActionErrorMessage = response.error ?: "Fork failed") }
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isForkingMessage = false, messageActionErrorMessage = e.message) }
            }
        }
    }

    fun regenerateAssistantResponse(context: MessageActionContext) {
        if (context.role != MessageActionContext.Role.Assistant) return
        val messages = _uiState.value.messages
        val assistantIndex = messages.indexOfFirst { it.id == context.messageId }
        if (assistantIndex < 0) return

        // Find the preceding user message to replay
        val userMessageIndex = messages.subList(0, assistantIndex)
            .indexOfLast { it.role == "user" }
        if (userMessageIndex < 0) return
        val userText = messages[userMessageIndex].content?.trim()?.takeIf { it.isNotEmpty() } ?: return

        viewModelScope.launch {
            _uiState.update { it.copy(isRegeneratingMessage = true, messageActionErrorMessage = null) }
            try {
                // Truncate before the user message so sendMessage won't duplicate it
                val keepCount = _uiState.value.messageOffset + userMessageIndex
                val truncateResponse = apiClient.sessionTruncate(sessionId, keepCount)
                val truncatedMessages = messages.take(userMessageIndex)
                _uiState.update { state ->
                    state.copy(
                        messages = truncatedMessages,
                        displayedTranscriptMessages = buildTranscriptMessages(truncatedMessages, null, state.messageOffset),
                        isRegeneratingMessage = false
                    )
                }
                sendMessage(userText)
            } catch (e: Exception) {
                _uiState.update { it.copy(isRegeneratingMessage = false, messageActionErrorMessage = e.message) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Listen (TTS)
    // -------------------------------------------------------------------------

    fun toggleListening(context: MessageActionContext) {
        if (context.role != MessageActionContext.Role.Assistant) return
        val text = context.copyText
        if (text.isBlank()) return

        val state = _uiState.value
        if (state.listeningMessageId == context.messageId && state.isListening) {
            stopListening()
            return
        }

        stopListening()
        _uiState.update { it.copy(listeningMessageId = context.messageId, isListening = true) }
        if (ttsInitialized) {
            val result = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, context.messageId)
            if (result == TextToSpeech.ERROR) clearListeningState(context.messageId)
        } else {
            clearListeningState(context.messageId)
        }
    }

    private fun clearListeningState(utteranceId: String?) {
        _uiState.update { state ->
            if (utteranceId == null || state.listeningMessageId == utteranceId) {
                state.copy(listeningMessageId = null, isListening = false)
            } else {
                state
            }
        }
    }

    fun stopListening() {
        textToSpeech?.stop()
        _uiState.update { it.copy(listeningMessageId = null, isListening = false) }
    }

    // -------------------------------------------------------------------------
    // Pending action responses
    // -------------------------------------------------------------------------

    fun respondToApproval(approved: Boolean) {
        val pending = _uiState.value.approvalPending ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(isRespondingToPendingAction = true, pendingActionErrorMessage = null) }
            try {
                val request = ChatSteerRequest(sessionId, if (approved) "approve" else "reject")
                apiClient.chatSteer(request)
                _uiState.update { it.copy(isRespondingToPendingAction = false, approvalPending = null) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isRespondingToPendingAction = false, pendingActionErrorMessage = e.message) }
            }
        }
    }

    fun respondToClarification(choice: String) {
        val pending = _uiState.value.clarificationPending ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(isRespondingToPendingAction = true, pendingActionErrorMessage = null) }
            try {
                val request = ChatSteerRequest(sessionId, choice)
                apiClient.chatSteer(request)
                _uiState.update { it.copy(isRespondingToPendingAction = false, clarificationPending = null) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isRespondingToPendingAction = false, pendingActionErrorMessage = e.message) }
            }
        }
    }

    fun dismissPendingAction() {
        _uiState.update { it.copy(approvalPending = null, clarificationPending = null, pendingActionErrorMessage = null) }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private fun buildTranscriptMessages(
        messages: List<ChatMessage>,
        hidingStreamingAssistantId: String?,
        messageOffset: Int
    ): List<TranscriptMessage> {
        return messages.mapIndexedNotNull { index, message ->
            if (message.role == "tool") return@mapIndexedNotNull null
            if (hidingStreamingAssistantId != null && message.messageId == hidingStreamingAssistantId) return@mapIndexedNotNull null
            val anchorId = message.messageId ?: "anchor-$index"
            val fullHistoryIndex = messageOffset + index
            TranscriptMessage(
                loadedIndex = index,
                fullHistoryIndex = fullHistoryIndex,
                keepCountThroughMessage = fullHistoryIndex + 1,
                renderId = "transcript-$fullHistoryIndex",
                anchorId = anchorId,
                message = message
            )
        }
    }

    private fun emitScrollToBottom() {
        viewModelScope.launch {
            _scrollToBottomEvent.emit(Unit)
        }
    }

    data class CompressionAnchorMetadata(val placeholder: String = "")
}
