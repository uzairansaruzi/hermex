package com.hermexapp.android.features.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.features.chat.ChatViewModel.TimelineEntry
import com.hermexapp.android.ui.CircleButton
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.theme.LocalHermexPalette

@Composable
fun ChatScreen(
    viewModel: ChatViewModel,
    onBack: () -> Unit,
    onOpenFiles: () -> Unit = {},
    onOpenGit: () -> Unit = {},
    onRunFinished: (String?) -> Unit = {},
) {
    val state by viewModel.uiState.collectAsState()
    val listState = rememberLazyListState()
    val haptics = LocalHapticFeedback.current
    val palette = LocalHermexPalette.current

    LaunchedEffect(Unit) { viewModel.load() }
    DisposableEffect(Unit) { onDispose { viewModel.teardown() } }

    // Completion signal: haptic + notification hook, once per finished run.
    LaunchedEffect(state.finishedRunCount) {
        if (state.finishedRunCount > 0) {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            onRunFinished(state.title)
        }
    }

    // Follow the stream: keep the newest entry visible as it grows.
    LaunchedEffect(state.entries.size, (state.entries.lastOrNull() as? TimelineEntry.AssistantMessage)?.text?.length) {
        if (state.entries.isNotEmpty()) {
            listState.animateScrollToItem(state.entries.lastIndex)
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().imePadding(),
        containerColor = palette.canvas,
        topBar = {
            HermexHeader(
                title = state.title ?: "New chat",
                subtitle = "hermes",
                onBack = onBack,
                actions = {
                    CircleButton(onClick = onOpenFiles, glyph = "📁", size = 40)
                    CircleButton(onClick = onOpenGit, glyph = "⎇", size = 40)
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            AnimatedVisibility(visible = state.isFromCache) {
                Text(
                    "Offline — showing the cached transcript.",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.warning,
                )
            }

            AnimatedVisibility(visible = state.errorMessage != null) {
                Text(
                    state.errorMessage.orEmpty(),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = palette.destructive,
                )
            }

            when {
                state.isLoading && state.entries.isEmpty() ->
                    Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = palette.accent)
                    }

                state.entries.isEmpty() ->
                    Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("No messages yet", style = MaterialTheme.typography.titleMedium)
                            Text(
                                "Ask anything to start the run.",
                                style = MaterialTheme.typography.bodySmall,
                                color = palette.textSecondary,
                            )
                        }
                    }

                else -> LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    state = listState,
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    items(state.entries, key = { it.id }) { entry ->
                        TimelineEntryView(entry, isStreamingRun = state.isStreaming)
                    }
                }
            }

            SlashSuggestionList(
                suggestions = state.slashSuggestions,
                onPick = viewModel::applySlashCommand,
            )
            AttachmentStrip(state, viewModel)
            ComposerBar(
                viewModel = viewModel,
                state = state,
                onSendHaptic = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) },
                onStopHaptic = { haptics.performHapticFeedback(HapticFeedbackType.LongPress) },
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TimelineEntryView(entry: TimelineEntry, isStreamingRun: Boolean) {
    val clipboard = LocalClipboardManager.current
    val haptics = LocalHapticFeedback.current
    val palette = LocalHermexPalette.current

    fun copyModifier(text: String): Modifier = Modifier.combinedClickable(
        onClick = {},
        onLongClick = {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            clipboard.setText(AnnotatedString(text))
        },
    )

    when (entry) {
        // iOS user bubble: gray rounded, right-aligned, ~80% max width.
        is TimelineEntry.UserMessage -> Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Surface(
                color = palette.bubble,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.widthIn(max = 320.dp).then(copyModifier(entry.text)),
            ) {
                Text(
                    entry.text,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }

        // iOS assistant text: plain on the black canvas, no bubble.
        is TimelineEntry.AssistantMessage -> Text(
            entry.text + if (entry.isStreaming) " ▍" else "",
            style = MaterialTheme.typography.bodyLarge,
            modifier = copyModifier(entry.text),
        )

        // iOS "Thinking" card: dark, collapsible, preview in the header.
        is TimelineEntry.Reasoning -> ThinkingCard(entry, isStreamingRun)

        is TimelineEntry.ToolCall -> Surface(
            color = palette.card,
            shape = MaterialTheme.shapes.small,
        ) {
            Column(modifier = Modifier.padding(12.dp).fillMaxWidth()) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("🛠", style = MaterialTheme.typography.labelMedium)
                    Text(
                        entry.name ?: "tool",
                        style = MaterialTheme.typography.labelLarge,
                    )
                    Text(
                        when {
                            entry.isRunning -> "running…"
                            entry.isError -> "failed"
                            else -> entry.durationSeconds?.let { "%.1fs".format(it) } ?: "done"
                        },
                        style = MaterialTheme.typography.labelMedium,
                        color = when {
                            entry.isError -> palette.destructive
                            entry.isRunning -> palette.warning
                            else -> palette.textSecondary
                        },
                    )
                }
                entry.preview?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = palette.textSecondary,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        is TimelineEntry.Notice -> Text(
            entry.text,
            modifier = Modifier.fillMaxWidth(),
            style = MaterialTheme.typography.labelMedium,
            color = palette.textSecondary,
        )
    }
}

@Composable
private fun ThinkingCard(entry: TimelineEntry.Reasoning, isStreamingRun: Boolean) {
    val palette = LocalHermexPalette.current
    // Expanded while it streams (like iOS), collapses to the header afterwards
    // unless the user toggles it.
    var userToggled by remember(entry.id) { mutableStateOf<Boolean?>(null) }
    val expanded = userToggled ?: (entry.isStreaming && isStreamingRun)

    Surface(
        color = palette.card,
        shape = MaterialTheme.shapes.small,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                .clickable(onClick = { userToggled = !(expanded) })
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("🧠", style = MaterialTheme.typography.labelMedium)
                Text("Thinking", style = MaterialTheme.typography.labelLarge)
                if (!expanded) {
                    Text(
                        entry.text.lineSequence().firstOrNull().orEmpty(),
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                } else {
                    androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                }
                Text(
                    if (expanded) "⌃" else "⌄",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.textSecondary,
                )
            }
            if (expanded) {
                Text(
                    entry.text + if (entry.isStreaming) " ▍" else "",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.85f),
                )
            }
        }
    }
}
