package com.hermex.app.ui.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import com.hermex.app.data.model.ChatMessage
import com.hermex.app.data.model.ToolStreamEvent
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ChatTranscriptView(
    isLoading: Boolean,
    errorMessage: String?,
    messages: List<ChatMessage>,
    transcriptMessages: List<TranscriptMessage>,
    liveReasoningText: String,
    liveToolCalls: List<ToolStreamEvent>,
    streamingAssistantMessageId: String?,
    completedReasoningGroups: List<ReasoningGroup>,
    completedToolCallGroups: List<ToolCallDisplay>,
    onScrollToBottom: suspend () -> Unit,
    onAction: (MessageActionContext, ChatMessageAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    var userScrolledUp by remember { mutableStateOf(false) }

    LaunchedEffect(listState, transcriptMessages.size) {
        snapshotFlow {
            val total = listState.layoutInfo.totalItemsCount
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            total > 0 && lastVisible < total - 2
        }.collect { scrolledUp -> userScrolledUp = scrolledUp }
    }

    LaunchedEffect(messages.size, liveReasoningText, liveToolCalls.size) {
        if (!userScrolledUp) {
            scrollToBottom(listState)
            onScrollToBottom()
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        when {
            isLoading && messages.isEmpty() -> {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            errorMessage != null && messages.isEmpty() -> {
                EmptyTranscriptPlaceholder(
                    title = "Could Not Load Messages",
                    description = errorMessage
                )
            }
            messages.isEmpty() -> {
                EmptyTranscriptPlaceholder(
                    title = "Send a message",
                    description = "Send a message to start the conversation."
                )
            }
            else -> {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(vertical = 12.dp)
                ) {
                    items(transcriptMessages, key = { it.renderId }) { transcriptMessage ->
                        val message = transcriptMessage.message
                        val isStreaming = streamingAssistantMessageId != null && message.messageId == streamingAssistantMessageId
                        val reasoningForRow = completedReasoningGroups.filter { it.anchorMessageId == transcriptMessage.anchorId }
                        val toolsForRow = completedToolCallGroups.filter { it.anchorMessageId == transcriptMessage.anchorId }
                        val actionContext = remember(transcriptMessage) { buildActionContext(transcriptMessage) }
                        var menuExpanded by remember(transcriptMessage.renderId) { mutableStateOf(false) }

                        Box(modifier = Modifier.fillMaxWidth()) {
                            Column(
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .combinedClickable(
                                        onClick = {},
                                        onLongClick = {
                                            if (actionContext != null) {
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                menuExpanded = true
                                            }
                                        }
                                    )
                            ) {
                                reasoningForRow.forEach { ReasoningBlockView(text = it.text) }
                                toolsForRow.forEach { ToolCallCardView(toolCall = it.toolCall, isCompleted = it.isCompleted) }
                                MessageBubbleView(message = message, isStreaming = isStreaming)
                            }
                            actionContext?.let { context ->
                                MessageActionDropdownMenu(
                                    expanded = menuExpanded,
                                    context = context,
                                    onDismiss = { menuExpanded = false },
                                    onAction = { action ->
                                        menuExpanded = false
                                        onAction(context, action)
                                    }
                                )
                            }
                        }
                    }

                    item(key = "live-blocks") {
                        if (streamingAssistantMessageId != null) {
                            LiveStreamingBlocks(
                                liveReasoningText = liveReasoningText,
                                liveToolCalls = liveToolCalls
                            )
                        }
                    }

                    item(key = "bottom-spacer") {
                        Spacer(modifier = Modifier.height(8.dp))
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = userScrolledUp && messages.isNotEmpty(),
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.BottomEnd)
        ) {
            FloatingActionButton(
                onClick = {
                    coroutineScope.launch {
                        scrollToBottom(listState)
                        onScrollToBottom()
                        userScrolledUp = false
                    }
                },
                modifier = Modifier.padding(16.dp).size(44.dp),
                containerColor = MaterialTheme.colorScheme.surface,
                contentColor = MaterialTheme.colorScheme.onSurface
            ) {
                Icon(Icons.Default.ArrowDownward, contentDescription = "Scroll to bottom")
            }
        }
    }
}

private suspend fun scrollToBottom(listState: LazyListState) {
    val count = listState.layoutInfo.totalItemsCount
    if (count > 0) listState.animateScrollToItem(count - 1)
}

private fun buildActionContext(transcriptMessage: TranscriptMessage): MessageActionContext? {
    val message = transcriptMessage.message
    val content = message.content?.takeIf { it.isNotBlank() } ?: return null
    val keepCount = transcriptMessage.loadedIndex + 1
    return when (message.role) {
        "user" -> MessageActionContext.UserContext(
            visibleIndex = transcriptMessage.loadedIndex,
            fullHistoryIndex = transcriptMessage.loadedIndex,
            keepCountThroughMessage = keepCount,
            messageId = message.id,
            copyText = content
        )
        "assistant" -> MessageActionContext.AssistantContext(
            visibleIndex = transcriptMessage.loadedIndex,
            fullHistoryIndex = transcriptMessage.loadedIndex,
            keepCountThroughMessage = keepCount,
            messageId = message.id,
            copyText = content
        )
        else -> null
    }
}

@Composable
private fun MessageActionDropdownMenu(
    expanded: Boolean,
    context: MessageActionContext,
    onDismiss: () -> Unit,
    onAction: (ChatMessageAction) -> Unit
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Copy") }, onClick = { onAction(ChatMessageAction.Copy) })
        DropdownMenuItem(text = { Text("Fork From Here") }, onClick = { onAction(ChatMessageAction.Fork) })
        when (context.role) {
            MessageActionContext.Role.User -> {
                DropdownMenuItem(text = { Text("Edit Message") }, onClick = { onAction(ChatMessageAction.Edit) })
            }
            MessageActionContext.Role.Assistant -> {
                DropdownMenuItem(text = { Text("Listen") }, onClick = { onAction(ChatMessageAction.Listen) })
                DropdownMenuItem(text = { Text("Regenerate") }, onClick = { onAction(ChatMessageAction.Regenerate) })
            }
        }
    }
}

@Composable
private fun LiveStreamingBlocks(
    liveReasoningText: String,
    liveToolCalls: List<ToolStreamEvent>
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        if (liveReasoningText.isNotBlank()) ReasoningBlockView(text = liveReasoningText)
        liveToolCalls.forEach { toolCall ->
            ToolCallCardView(toolCall = toolCall, isCompleted = toolCall.result != null)
        }
    }
}

@Composable
private fun EmptyTranscriptPlaceholder(
    title: String,
    description: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null
) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text = title, style = MaterialTheme.typography.titleMedium)
            if (description != null) {
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(top = 8.dp, start = 32.dp, end = 32.dp)
                )
            }
            if (actionLabel != null && onAction != null) {
                Button(onClick = onAction, modifier = Modifier.padding(top = 16.dp)) { Text(actionLabel) }
            }
        }
    }
}

enum class ChatMessageAction {
    Copy,
    Edit,
    Fork,
    Regenerate,
    Listen
}
