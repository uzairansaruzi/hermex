package com.hermexapp.android.features.sessionlist

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.model.Project
import com.hermexapp.android.model.SessionSummary
import com.hermexapp.android.ui.CircleButton
import com.hermexapp.android.ui.HermexPickerSheet
import com.hermexapp.android.ui.HermexWordmark
import com.hermexapp.android.ui.PickerRow
import com.hermexapp.android.ui.PickerSection
import com.hermexapp.android.ui.relativeTimeAgo
import com.hermexapp.android.ui.theme.LocalHermexPalette
import kotlinx.coroutines.launch

/**
 * The iOS home screen: HERMEX wordmark, panel menu rows, a "Sessions" section
 * with relative timestamps, and the floating "✎ Chat" pill.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionListScreen(
    viewModel: SessionListViewModel,
    onOpenSession: (String) -> Unit,
    onOpenPanel: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenProjects: () -> Unit = {},
) {
    val state by viewModel.uiState.collectAsState()
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val palette = LocalHermexPalette.current
    var searchVisible by remember { mutableStateOf(false) }
    var actionTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var renameTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var moveTarget by remember { mutableStateOf<SessionSummary?>(null) }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = palette.canvas,
        floatingActionButton = {
            Surface(
                onClick = {
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    scope.launch { viewModel.createSessionNow()?.let(onOpenSession) }
                },
                color = palette.pillBackground,
                contentColor = palette.pillForeground,
                shape = CircleShape,
                shadowElevation = 6.dp,
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("✎", fontWeight = FontWeight.Bold)
                    Text("Chat", style = MaterialTheme.typography.titleSmall, color = palette.pillForeground)
                }
            }
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(innerPadding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 88.dp),
        ) {
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HermexWordmark()
                    Spacer(Modifier.weight(1f))
                    CircleButton(
                        onClick = {
                            searchVisible = !searchVisible
                            if (!searchVisible) viewModel.updateSearchQuery("")
                        },
                        icon = Icons.Filled.Search,
                        size = 40,
                    )
                    Spacer(Modifier.size(8.dp))
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .background(palette.accent, CircleShape)
                            .clickable(onClick = onOpenSettings),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Filled.Settings,
                            contentDescription = "Settings",
                            tint = palette.canvas,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }

            if (searchVisible) {
                item {
                    OutlinedTextField(
                        value = state.searchQuery,
                        onValueChange = viewModel::updateSearchQuery,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 4.dp),
                        placeholder = { Text("Search sessions", color = palette.textSecondary) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = palette.card,
                            unfocusedContainerColor = palette.card,
                            focusedBorderColor = palette.card,
                            unfocusedBorderColor = palette.card,
                        ),
                    )
                }
            }

            item {
                Column(modifier = Modifier.padding(horizontal = 8.dp)) {
                    MenuRow(Icons.Filled.List, "Projects") { onOpenProjects() }
                    MenuRow(Icons.Filled.DateRange, "Tasks") { onOpenPanel("TASKS") }
                    MenuRow(Icons.Filled.Build, "Skills") { onOpenPanel("SKILLS") }
                    MenuRow(Icons.Filled.Face, "Memory") { onOpenPanel("MEMORY") }
                    MenuRow(Icons.Filled.Info, "Insights") { onOpenPanel("INSIGHTS") }
                }
            }

            item {
                Text(
                    "Sessions",
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                    style = MaterialTheme.typography.titleLarge,
                )
            }

            item {
                AnimatedVisibility(visible = state.isFromCache) {
                    Text(
                        "Offline — showing cached sessions.",
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.warning,
                    )
                }
            }

            item {
                AnimatedVisibility(visible = state.errorMessage != null) {
                    Column(modifier = Modifier.padding(horizontal = 20.dp)) {
                        Text(
                            state.errorMessage.orEmpty(),
                            style = MaterialTheme.typography.bodySmall,
                            color = palette.destructive,
                        )
                        TextButton(onClick = { viewModel.refresh() }) { Text("Retry") }
                    }
                }
            }

            when {
                state.isLoading && state.sessions.isEmpty() -> item {
                    Box(
                        Modifier.fillMaxWidth().padding(vertical = 48.dp),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator(color = palette.accent) }
                }

                state.sessions.isEmpty() && state.errorMessage == null -> item {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            if (state.searchQuery.isBlank()) "No sessions yet" else "No matches",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            if (state.searchQuery.isBlank()) "Tap Chat to start one." else "Try another search.",
                            style = MaterialTheme.typography.bodySmall,
                            color = palette.textSecondary,
                        )
                    }
                }

                else -> items(state.sessions, key = { it.stableId }) { session ->
                    SwipeableSessionRow(
                        session = session,
                        modifier = Modifier.animateItem(),
                        onClick = { session.sessionId?.let(onOpenSession) },
                        onLongClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            actionTarget = session
                        },
                        onArchive = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            session.sessionId?.let { viewModel.archiveSession(it, session.archived != true) }
                        },
                        onDelete = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            deleteTarget = session
                        },
                    )
                }
            }
        }
    }

    actionTarget?.let { session ->
        SessionActionsDialog(
            session = session,
            onDismiss = { actionTarget = null },
            onRename = { renameTarget = session; actionTarget = null },
            onDelete = { deleteTarget = session; actionTarget = null },
            onPinToggle = {
                session.sessionId?.let { viewModel.pinSession(it, session.pinned != true) }
                actionTarget = null
            },
            onArchiveToggle = {
                session.sessionId?.let { viewModel.archiveSession(it, session.archived != true) }
                actionTarget = null
            },
            onMove = { moveTarget = session; actionTarget = null },
            onDuplicate = {
                actionTarget = null
                session.sessionId?.let { id ->
                    scope.launch { viewModel.duplicateSessionNow(id)?.let(onOpenSession) }
                }
            },
            onFork = {
                actionTarget = null
                session.sessionId?.let { id ->
                    scope.launch { viewModel.branchSessionNow(id)?.let(onOpenSession) }
                }
            },
        )
    }

    moveTarget?.let { session ->
        MoveToProjectSheet(
            projects = state.projects,
            currentProjectId = session.projectId,
            onPick = { projectId ->
                session.sessionId?.let { viewModel.moveSession(it, projectId) }
                moveTarget = null
            },
            onDismiss = { moveTarget = null },
        )
    }

    renameTarget?.let { session ->
        RenameDialog(
            initial = session.title.orEmpty(),
            onDismiss = { renameTarget = null },
            onConfirm = { title ->
                session.sessionId?.let { viewModel.renameSession(it, title) }
                renameTarget = null
            },
        )
    }

    deleteTarget?.let { session ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete session?") },
            text = { Text("\"${session.title ?: "Untitled"}\" will be removed from the server.") },
            confirmButton = {
                TextButton(onClick = {
                    session.sessionId?.let(viewModel::deleteSession)
                    deleteTarget = null
                }) { Text("Delete", color = palette.destructive) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

/** The icon + label menu rows under the wordmark (Tasks / Skills / Memory / Insights). */
@Composable
private fun MenuRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.size(22.dp),
        )
        Text(label, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun SessionActionsDialog(
    session: SessionSummary,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onPinToggle: () -> Unit,
    onArchiveToggle: () -> Unit,
    onMove: () -> Unit,
    onDuplicate: () -> Unit,
    onFork: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        title = {
            Text(
                session.title ?: "Untitled session",
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        text = {
            Column {
                TextButton(onClick = onRename) { Text("Rename") }
                TextButton(onClick = onMove) { Text("Move to project") }
                TextButton(onClick = onDuplicate) { Text("Duplicate") }
                TextButton(onClick = onFork) { Text("Fork") }
                TextButton(onClick = onPinToggle) {
                    Text(if (session.pinned == true) "Unpin" else "Pin")
                }
                TextButton(onClick = onArchiveToggle) {
                    Text(if (session.archived == true) "Unarchive" else "Archive")
                }
                TextButton(onClick = onDelete) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            }
        },
    )
}

/** Project picker for "Move to project", with a "No project" un-file row. */
@Composable
private fun MoveToProjectSheet(
    projects: List<Project>,
    currentProjectId: String?,
    onPick: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    // Sentinel for the "no project" row — HermexPickerSheet keys on the value.
    val noProject = ""
    HermexPickerSheet(
        title = "Move to project",
        sections = listOf(
            PickerSection(
                header = null,
                rows = buildList {
                    add(PickerRow("No project", noProject))
                    projects.forEach { p ->
                        add(PickerRow(p.name?.ifBlank { null } ?: "Untitled", p.projectId ?: return@forEach))
                    }
                },
            ),
        ),
        isSelected = { value -> value == (currentProjectId ?: noProject) },
        onPick = { value -> onPick(value.ifBlank { null }) },
        onDismiss = onDismiss,
        searchable = false,
    )
}

@Composable
private fun RenameDialog(
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var title by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename session") },
        text = {
            OutlinedTextField(value = title, onValueChange = { title = it }, singleLine = true)
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(title.trim()) },
                enabled = title.isNotBlank(),
            ) { Text("Rename") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * iOS-style swipe actions: swipe right to Archive, swipe left to Delete. Neither
 * gesture actually dismisses the row — both snap back and let the list refresh
 * reflect the change (delete waits for the confirm dialog).
 */
@OptIn(ExperimentalFoundationApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableSessionRow(
    session: SessionSummary,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onArchive: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = LocalHermexPalette.current
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> onArchive()
                SwipeToDismissBoxValue.EndToStart -> onDelete()
                SwipeToDismissBoxValue.Settled -> Unit
            }
            false // never settle dismissed; the list refresh handles the change
        },
    )
    SwipeToDismissBox(
        state = dismissState,
        modifier = modifier,
        backgroundContent = {
            val toEnd = dismissState.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            val color = if (toEnd) palette.warning else palette.destructive
            val label = if (toEnd) (if (session.archived == true) "Unarchive" else "Archive") else "Delete"
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .background(color.copy(alpha = 0.18f))
                    .padding(horizontal = 24.dp),
                horizontalArrangement = if (toEnd) Arrangement.Start else Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, style = MaterialTheme.typography.labelLarge, color = color)
            }
        },
    ) {
        Surface(color = palette.canvas) {
            SessionRow(session = session, onClick = onClick, onLongClick = onLongClick)
        }
    }
}

/** iOS session row: bold title, "N messages · workspace" caption, relative time. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(
    session: SessionSummary,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val palette = LocalHermexPalette.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (session.pinned == true) {
                    Text("📌", style = MaterialTheme.typography.labelSmall)
                }
                Text(
                    session.title?.ifBlank { null } ?: "Untitled session",
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                listOfNotNull(
                    session.messageCount?.let { "$it messages" },
                    session.workspace?.substringAfterLast('/')?.ifBlank { null }
                        ?: session.profile,
                    if (session.isCronSession) "cron" else null,
                    if (session.isCliSession == true) "cli" else null,
                    if (session.archived == true) "archived" else null,
                ).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                relativeTimeAgo(session.lastMessageAt ?: session.updatedAt ?: session.createdAt),
                style = MaterialTheme.typography.bodySmall,
                color = palette.textSecondary,
            )
            if (session.isStreaming == true || session.activeStreamId != null) {
                Box(Modifier.size(8.dp).background(palette.success, CircleShape))
            }
        }
    }
}
