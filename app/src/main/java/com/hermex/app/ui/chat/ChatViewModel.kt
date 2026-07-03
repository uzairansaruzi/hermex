package com.hermex.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.speech.tts.TextToSpeech
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
    private val notificationManager: HermexNotificationManager
) : ViewModel() {

    private val sessionId: String = savedStateHandle.get<String>("sessionId")
        ?: throw IllegalArgumentException("ChatViewModel requires a sessionId argument")

    private val _uiState = MutableStateFlow(ChatUiState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private var currentStreamId: String? = null
    private var streamingJob: Job? = null

    private var pendingAssistantTokenChunks = mutableListOf<String>()
    private var pendingReasoningChunks = mutableListOf<String>()
    private var pendingStreamingContentFlushJob: Job? = null
    private var pendingScrollTriggerJob: Job? = null

    private val _scrollToBottomEvent = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val scrollToBottomEvent: SharedFlow<Unit> = _scrollToBottomEvent.asSharedFlow()

    private var textToSpeech: TextToSpeech? = null
    private var ttsInitialized = false

    private val compressionAnchorMetadata: CompressionAnchorMetadata? = null

    init {
        textToSpeech = TextToSpeech(appContext) { status ->
            ttsInitialized = status == TextToSpeech.SUCCESS
        }
        loadMessages()
        loadComposerConfiguration()
    }

    override fun onCleared() {
        super.onCleared()
        stopStreaming()
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
                val title = session?.title?.takeIf { it.isNotBlank() } ?: "Untitled Session"

                _uiState.update { state ->
                    state.copy(
                        isLoading = false,
                        messages = loadedMessages,
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
                        displayedTranscriptMessages = buildTranscriptMessages(loadedMessages, null),
                        errorMessage = null
                    )
                }
                emitScrollToBottom()
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false, errorMessage = e.message ?: "Failed to load messages") }
            }
        }
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
        viewModelScope.launch {
            _uiState.update { it.copy(isUpdatingComposerConfig = true, composerErrorMessage = null) }
            try {
                apiClient.defaultModel(model)
                _uiState.update { state ->
                    state.copy(
                        isUpdatingComposerConfig = false,
                        currentModel = model,
                        currentModelProvider = provider
                    )
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isUpdatingComposerConfig = false, composerErrorMessage = e.message) }
            }
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
                    displayedTranscriptMessages = buildTranscriptMessages(previousMessages + optimisticMessage, null)
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
                            sendErrorMessage = response.streamId?.let { null } ?: "The server did not return a stream ID."
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
                        displayedTranscriptMessages = buildTranscriptMessages(messagesWithoutOptimistic, null)
                    )
                }
            }
        }
    }

    private fun startStream(streamId: String) {
        stopStreaming()
        currentStreamId = streamId
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
                            _uiState.update { it.copy(sendErrorMessage = event.message) }
                            finishStream()
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
                _uiState.update { it.copy(sendErrorMessage = e.message ?: "Stream error") }
                finishStream()
            }
        }
    }

    private fun appendToken(token: String) {
        if (token.isEmpty()) return
        val streamingId = ensureStreamingAssistantMessage()
        val flushedContent = _uiState.value.messages.find { it.messageId == streamingId }?.content ?: ""
        val effectiveContent = flushedContent + pendingAssistantTokenChunks.joinToString("")
        val remainder = deduplicateToken(token, effectiveContent)
        if (remainder.isEmpty()) return
        pendingAssistantTokenChunks.add(remainder)
        scheduleStreamingContentFlush()
    }

    private fun appendReasoning(text: String) {
        if (text.isEmpty()) return
        val streamingId = ensureStreamingAssistantMessage()
        val effectiveContent = _uiState.value.liveReasoningText + pendingReasoningChunks.joinToString("")
        val remainder = deduplicateToken(text, effectiveContent)
        if (remainder.isEmpty()) return
        pendingReasoningChunks.add(remainder)
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
                        displayedTranscriptMessages = buildTranscriptMessages(messages, streamingId)
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
                displayedTranscriptMessages = buildTranscriptMessages(messages, null)
            )
        }
    }

    fun stopStreaming() {
        val streamId = currentStreamId ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(isCancellingStream = true) }
            try {
                apiClient.chatCancel(streamId)
            } catch (_: Exception) {
            } finally {
                sseClient.stop()
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
                displayedTranscriptMessages = buildTranscriptMessages(updated, state.streamingAssistantMessageId)
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
                displayedTranscriptMessages = buildTranscriptMessages(state.messages + newMessage, id)
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
                displayedTranscriptMessages = buildTranscriptMessages(messages, streamingId)
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
        val offset = 0
        val fullHistoryIndex = offset + visibleIndex
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
        val index = messages.indexOfFirst { it.messageId == context.messageId }
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
                        displayedTranscriptMessages = buildTranscriptMessages(truncatedMessages, null),
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
        val index = messages.indexOfFirst { it.messageId == context.messageId }
        val userText = if (index > 0) {
            messages.subList(0, index).findLast { it.role == "user" }?.content?.trim()?.takeIf { it.isNotEmpty() }
        } else null
        if (userText == null) return

        viewModelScope.launch {
            _uiState.update { it.copy(isRegeneratingMessage = true, messageActionErrorMessage = null) }
            try {
                val keepCount = context.keepCountThroughMessage - 1
                val truncateResponse = apiClient.sessionTruncate(sessionId, keepCount)
                val truncatedMessages = messages.take(index)
                _uiState.update {
                    it.copy(
                        messages = truncatedMessages,
                        displayedTranscriptMessages = buildTranscriptMessages(truncatedMessages, null),
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
            textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, context.messageId)
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
        hidingStreamingAssistantId: String?
    ): List<TranscriptMessage> {
        return messages.mapIndexedNotNull { index, message ->
            if (message.role == "tool") return@mapIndexedNotNull null
            if (hidingStreamingAssistantId != null && message.messageId == hidingStreamingAssistantId) return@mapIndexedNotNull null
            val anchorId = message.messageId ?: "anchor-$index"
            TranscriptMessage(
                loadedIndex = index,
                renderId = "transcript-$index",
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
