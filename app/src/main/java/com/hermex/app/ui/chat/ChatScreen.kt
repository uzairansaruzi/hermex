package com.hermex.app.ui.chat

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.hermex.app.ui.chat.slash.ClientSideAction
import com.hermex.app.ui.chat.slash.ParsedSlashQuery
import com.hermex.app.ui.chat.slash.SlashCommandCatalog
import com.hermex.app.ui.chat.slash.SlashCommandHandler

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    sessionId: String,
    initialDraft: String = "",
    autoStartVoiceInput: Boolean = false,
    onBack: () -> Unit,
    onNavigateToSession: (String) -> Unit = {},
    onNewSession: () -> Unit = {},
    onNavigateToFileBrowser: (String) -> Unit,
    viewModel: ChatViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    var showMenu by remember { mutableStateOf(false) }
    var draft by remember(sessionId) { mutableStateOf(initialDraft) }
    var pendingAutoStartVoice by remember(sessionId, autoStartVoiceInput) { mutableStateOf(autoStartVoiceInput) }
    var editContext by remember { mutableStateOf<MessageActionContext?>(null) }
    var editText by remember { mutableStateOf("") }

    fun sendDraft() {
        val text = draft.trim()
        if (text.isEmpty()) return
        val parsed = ParsedSlashQuery(text)
        if (parsed.isSlashQuery && parsed.commandName.isNotBlank()) {
            val handled = handleClientSlashCommand(
                parsed = parsed,
                uiState = uiState,
                viewModel = viewModel,
                onNewSession = onNewSession
            )
            if (handled) {
                draft = ""
                return
            }
        }
        viewModel.sendMessage(text)
        draft = ""
    }

    editContext?.let { context ->
        AlertDialog(
            onDismissRequest = { editContext = null },
            title = { Text("Edit message") },
            text = {
                OutlinedTextField(
                    value = editText,
                    onValueChange = { editText = it },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.editMessage(context, editText)
                        editContext = null
                    },
                    enabled = editText.isNotBlank()
                ) { Text("Send edited") }
            },
            dismissButton = {
                TextButton(onClick = { editContext = null }) { Text("Cancel") }
            }
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(uiState.title.ifEmpty { "Chat" }, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                        if (uiState.activeStreamId != null) {
                            Text("Streaming...", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { showMenu = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = "Menu")
                    }
                    DropdownMenu(
                        expanded = showMenu,
                        onDismissRequest = { showMenu = false }
                    ) {
                        DropdownMenuItem(
                            text = { Text("Files") },
                            onClick = { showMenu = false; onNavigateToFileBrowser(sessionId) },
                            leadingIcon = { Icon(Icons.Default.Folder, contentDescription = null) }
                        )
                    }
                }
            )
        },
        bottomBar = {
            ChatComposerView(
                draft = draft,
                onDraftChange = { draft = it },
                isSending = uiState.isStartingChat,
                isCancellingStream = uiState.isCancellingStream,
                activeStreamId = uiState.activeStreamId,
                currentModel = uiState.currentModel,
                currentWorkspace = uiState.currentWorkspace,
                currentProfile = uiState.currentProfile,
                availableModels = uiState.availableModels,
                availableProfiles = uiState.availableProfiles,
                availableWorkspaces = uiState.availableWorkspaces,
                onSend = { sendDraft() },
                onStop = { viewModel.stopStreaming() },
                onModelSelected = { model, provider -> viewModel.selectModel(model, provider) },
                onWorkspaceSelected = { viewModel.selectWorkspace(it) },
                onProfileSelected = { viewModel.selectProfile(it) },
                autoStartVoiceInput = pendingAutoStartVoice,
                onAutoStartVoiceConsumed = { pendingAutoStartVoice = false },
                modifier = Modifier
                    .navigationBarsPadding()
                    .imePadding()
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            val errorMsg = uiState.errorMessage
                ?: uiState.sendErrorMessage
                ?: uiState.messageActionErrorMessage
                ?: uiState.composerErrorMessage
                ?: uiState.pendingActionErrorMessage
            errorMsg?.let { error ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                ) {
                    Text(
                        error,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            uiState.approvalPending?.let { approval ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.secondaryContainer
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Approval Required", style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.height(4.dp))
                        approval.displayPatternKeys?.forEach { key ->
                            Text("• $key", style = MaterialTheme.typography.bodySmall)
                        }
                        Spacer(Modifier.height(8.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilledTonalButton(onClick = { viewModel.respondToApproval(true) }) { Text("Approve") }
                            OutlinedButton(onClick = { viewModel.respondToApproval(false) }) { Text("Deny") }
                        }
                    }
                }
            }

            uiState.clarificationPending?.let { clarification ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.tertiaryContainer
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Clarification Needed", style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.height(4.dp))
                        Text(clarification.displayQuestion ?: "", style = MaterialTheme.typography.bodyMedium)
                        Spacer(Modifier.height(8.dp))
                        clarification.displayChoices?.forEach { choice ->
                            OutlinedButton(
                                onClick = { viewModel.respondToClarification(choice) },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
                            ) { Text(choice) }
                        }
                    }
                }
            }

            ChatTranscriptView(
                isLoading = uiState.isLoading,
                errorMessage = uiState.errorMessage,
                messages = uiState.messages,
                transcriptMessages = uiState.displayedTranscriptMessages,
                liveReasoningText = uiState.liveReasoningText,
                liveToolCalls = uiState.liveToolCalls,
                streamingAssistantMessageId = uiState.streamingAssistantMessageId,
                completedReasoningGroups = uiState.completedReasoningGroups,
                completedToolCallGroups = uiState.completedToolCallGroups,
                scrollToBottomEvent = viewModel.scrollToBottomEvent,
                onScrollToBottom = { },
                onAction = { context, action ->
                    when (action) {
                        ChatMessageAction.Copy -> viewModel.copyText(context)
                        ChatMessageAction.Edit -> {
                            editContext = context
                            editText = context.copyText
                        }
                        ChatMessageAction.Fork -> viewModel.forkFromMessage(context) { forkedSessionId ->
                            onNavigateToSession(forkedSessionId)
                        }
                        ChatMessageAction.Regenerate -> viewModel.regenerateAssistantResponse(context)
                        ChatMessageAction.Listen -> viewModel.toggleListening(context)
                    }
                }
            )
        }
    }
}

private fun handleClientSlashCommand(
    parsed: ParsedSlashQuery,
    uiState: ChatUiState,
    viewModel: ChatViewModel,
    onNewSession: () -> Unit
): Boolean {
    val command = parsed.command ?: return false
    val handler = command.handler
    if (handler !is SlashCommandHandler.ClientSide) return false
    when (handler.action) {
        ClientSideAction.Clear -> viewModel.clearTranscript()
        ClientSideAction.Stop -> viewModel.stopStreaming()
        ClientSideAction.New -> onNewSession()
        ClientSideAction.Help -> viewModel.appendLocalAssistantMessage(slashHelpText())
    }
    return true
}

private fun slashHelpText(): String = buildString {
    appendLine("Available slash commands:")
    SlashCommandCatalog.allCommands.forEach { command ->
        append("/").append(command.name)
        command.argHint?.let { append(" ").append(it) }
        append(" — ").appendLine(command.description)
    }
}
