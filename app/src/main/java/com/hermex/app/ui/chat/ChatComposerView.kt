package com.hermex.app.ui.chat

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.hermex.app.data.model.ProfileInfo
import com.hermex.app.ui.theme.HermexTheme
import com.hermex.app.ui.chat.slash.ParsedSlashQuery
import com.hermex.app.ui.chat.slash.SlashCommandCatalog
import com.hermex.app.ui.chat.slash.SlashCommandSubArgs
import java.util.Locale

@Composable
fun ChatComposerView(
    draft: String,
    onDraftChange: (String) -> Unit,
    isSending: Boolean,
    isCancellingStream: Boolean,
    activeStreamId: String?,
    currentModel: String?,
    currentWorkspace: String?,
    currentProfile: String?,
    availableModels: Map<String, List<String>>,
    availableProfiles: List<ProfileInfo>,
    availableWorkspaces: List<String>,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onModelSelected: (String, String?) -> Unit,
    onWorkspaceSelected: (String) -> Unit,
    onProfileSelected: (ProfileInfo) -> Unit,
    autoStartVoiceInput: Boolean = false,
    onAutoStartVoiceConsumed: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var modelMenuExpanded by remember { mutableStateOf(false) }
    var workspaceMenuExpanded by remember { mutableStateOf(false) }
    var profileMenuExpanded by remember { mutableStateOf(false) }
    var voiceError by remember { mutableStateOf<String?>(null) }

    fun speechIntent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
        putExtra(RecognizerIntent.EXTRA_PROMPT, "Message your Hermes agent")
    }

    val speechLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val transcript = result.data
            ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            ?.firstOrNull()
            ?.trim()
            .orEmpty()
        if (transcript.isNotEmpty()) {
            onDraftChange(listOf(draft.trim(), transcript).filter { it.isNotEmpty() }.joinToString(" "))
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            speechLauncher.launch(speechIntent())
        } else {
            voiceError = "Microphone permission is required for voice input."
        }
    }

    fun startVoiceInput() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            voiceError = "Speech recognition is not available on this Android device."
            return
        }
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (granted) speechLauncher.launch(speechIntent()) else permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
    }

    LaunchedEffect(autoStartVoiceInput) {
        if (autoStartVoiceInput) {
            startVoiceInput()
            onAutoStartVoiceConsumed()
        }
    }

    val canSend = draft.trim().isNotEmpty() && activeStreamId == null && !isSending
    val isStreaming = activeStreamId != null
    val parsedSlash = remember(draft) { ParsedSlashQuery(draft) }
    val slashSuggestions = remember(draft, availableModels, availableProfiles, availableWorkspaces) {
        buildSlashSuggestions(parsedSlash, availableModels, availableProfiles, availableWorkspaces)
    }

    Surface(
        tonalElevation = 2.dp,
        shadowElevation = 4.dp,
        modifier = modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
            if (slashSuggestions.isNotEmpty() && !isStreaming && !isSending) {
                SlashSuggestions(
                    suggestions = slashSuggestions,
                    onSelect = { suggestion ->
                        onDraftChange(suggestion.replacement)
                    }
                )
                Spacer(Modifier.height(8.dp))
            }

            voiceError?.let { error ->
                Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.height(6.dp))
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(bottom = 8.dp)
            ) {
                CompactDropdownChip(
                    label = currentModel?.substringAfterLast(":")?.substringAfterLast("/") ?: "Model",
                    expanded = modelMenuExpanded,
                    onExpandedChange = { modelMenuExpanded = it }
                ) {
                    availableModels.forEach { (provider, models) ->
                        models.forEach { model ->
                            DropdownMenuItem(
                                text = { Text("$provider / $model") },
                                onClick = {
                                    onModelSelected(model, provider)
                                    modelMenuExpanded = false
                                }
                            )
                        }
                    }
                }

                CompactDropdownChip(
                    label = currentWorkspace?.takeIf { it.isNotBlank() } ?: "Workspace",
                    expanded = workspaceMenuExpanded,
                    onExpandedChange = { workspaceMenuExpanded = it }
                ) {
                    availableWorkspaces.forEach { workspace ->
                        DropdownMenuItem(
                            text = { Text(workspace) },
                            onClick = {
                                onWorkspaceSelected(workspace)
                                workspaceMenuExpanded = false
                            }
                        )
                    }
                }

                CompactDropdownChip(
                    label = currentProfile?.takeIf { it.isNotBlank() } ?: "Profile",
                    expanded = profileMenuExpanded,
                    onExpandedChange = { profileMenuExpanded = it }
                ) {
                    availableProfiles.forEach { profile ->
                        DropdownMenuItem(
                            text = { Text(profile.name ?: "Default") },
                            onClick = {
                                profile.name?.let { onProfileSelected(profile) }
                                profileMenuExpanded = false
                            }
                        )
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    placeholder = { Text("Message your agent...") },
                    enabled = !isStreaming && !isSending,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(
                        onSend = { if (canSend) onSend() }
                    ),
                    modifier = Modifier.weight(1f),
                    minLines = 1,
                    maxLines = 6,
                    shape = RoundedCornerShape(22.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                        focusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                        unfocusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f),
                        disabledBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.2f)
                    )
                )

                if (!isStreaming) {
                    FilledTonalIconButton(
                        onClick = { startVoiceInput() },
                        enabled = !isSending,
                        modifier = Modifier.size(44.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    ) {
                        Icon(Icons.Default.Mic, contentDescription = "Voice input", modifier = Modifier.size(20.dp))
                    }
                }

                if (isStreaming) {
                    FilledIconButton(
                        onClick = onStop,
                        modifier = Modifier.size(44.dp),
                        colors = IconButtonDefaults.filledIconButtonColors(
                            containerColor = HermexTheme.colors.monochrome,
                            contentColor = HermexTheme.colors.onMonochrome
                        )
                    ) {
                        if (isCancellingStream) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = LocalContentColor.current)
                        } else {
                            Icon(Icons.Default.Stop, contentDescription = "Stop response", modifier = Modifier.size(18.dp))
                        }
                    }
                } else {
                    FilledIconButton(
                        onClick = onSend,
                        enabled = canSend,
                        modifier = Modifier.size(44.dp),
                        colors = IconButtonDefaults.filledIconButtonColors(
                            containerColor = HermexTheme.colors.monochrome,
                            contentColor = HermexTheme.colors.onMonochrome,
                            disabledContainerColor = HermexTheme.colors.monochrome.copy(alpha = 0.15f),
                            disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    ) {
                        if (isSending) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = LocalContentColor.current)
                        } else {
                            Icon(Icons.Default.ArrowUpward, contentDescription = "Send", modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }
        }
    }
}

private data class SlashSuggestion(
    val label: String,
    val description: String,
    val replacement: String
)

private fun buildSlashSuggestions(
    parsed: ParsedSlashQuery,
    availableModels: Map<String, List<String>>,
    availableProfiles: List<ProfileInfo>,
    availableWorkspaces: List<String>
): List<SlashSuggestion> {
    if (!parsed.isSlashQuery || parsed.commandName.isBlank() && parsed.query != "/") return emptyList()
    val command = parsed.command
    if (parsed.isSubArgMode && command != null) {
        val argQuery = parsed.argQuery.lowercase(Locale.ROOT)
        val values = when (command.subArgs) {
            SlashCommandSubArgs.Models -> availableModels.values.flatten()
            SlashCommandSubArgs.Personalities -> emptyList()
            SlashCommandSubArgs.ReasoningLevels -> SlashCommandCatalog.reasoningLevels
            SlashCommandSubArgs.Workspaces -> availableWorkspaces
            SlashCommandSubArgs.Skills -> emptyList()
            SlashCommandSubArgs.GoalActions -> SlashCommandCatalog.goalActions
            SlashCommandSubArgs.None -> emptyList()
        }
        return values
            .distinct()
            .filter { argQuery.isBlank() || it.lowercase(Locale.ROOT).contains(argQuery) }
            .take(8)
            .map { SlashSuggestion(it, command.description, "/${command.name} $it") }
    }

    return SlashCommandCatalog.matching(parsed.commandName)
        .take(8)
        .map { command ->
            SlashSuggestion(
                label = "/${command.name}${command.argHint?.let { " $it" } ?: ""}",
                description = command.description,
                replacement = "/${command.name}${if (command.argHint != null) " " else ""}"
            )
        }
}

@Composable
private fun SlashSuggestions(
    suggestions: List<SlashSuggestion>,
    onSelect: (SlashSuggestion) -> Unit
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        LazyColumn(modifier = Modifier.heightIn(max = 240.dp)) {
            items(suggestions) { suggestion ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(suggestion) }
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Text(
                        suggestion.label,
                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        suggestion.description,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun CompactDropdownChip(
    label: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    content: @Composable ColumnScope.() -> Unit
) {
    Box {
        AssistChip(
            onClick = { onExpandedChange(!expanded) },
            label = { Text(label, maxLines = 1) },
            border = null,
            colors = AssistChipDefaults.assistChipColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                labelColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        )
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { onExpandedChange(false) }
        ) {
            content()
        }
    }
}
