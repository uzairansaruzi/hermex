package com.hermex.app.ui.sessionlist

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pin
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material.DismissDirection
import androidx.compose.material.DismissValue
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.SwipeToDismiss
import androidx.compose.material.rememberDismissState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.hermex.app.R
import com.hermex.app.data.model.ProjectSummary
import com.hermex.app.data.model.SessionSummary
import com.hermex.app.ui.navigation.HermesLaunchRequest
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.map
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Calendar
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionListScreen(
    onSessionClick: (String) -> Unit,
    onNewChatCreated: (sessionId: String, initialDraft: String, autoStartVoice: Boolean) -> Unit = { sessionId, _, _ -> onSessionClick(sessionId) },
    pendingLaunchRequest: HermesLaunchRequest? = null,
    onLaunchRequestConsumed: () -> Unit = {},
    onReconnectClick: () -> Unit = {},
    onSettingsClick: () -> Unit,
    onTasksClick: () -> Unit,
    onSkillsClick: () -> Unit,
    onMemoryClick: () -> Unit,
    onInsightsClick: () -> Unit,
    viewModel: SessionListViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        viewModel.uiState.map { it.actionErrorMessage }
            .collectLatest { message ->
                message?.let {
                    snackbarHostState.showSnackbar(it)
                    viewModel.clearActionError()
                }
            }
    }

    LaunchedEffect(pendingLaunchRequest) {
        val request = pendingLaunchRequest ?: return@LaunchedEffect
        when (request) {
            is HermesLaunchRequest.OpenSession -> onSessionClick(request.sessionId)
            is HermesLaunchRequest.NewChat -> viewModel.createSession(profileName = request.profileName) { sessionId ->
                onNewChatCreated(sessionId, request.initialDraft, request.autoStartVoice)
            }
        }
        onLaunchRequestConsumed()
    }

    var sessionToDelete by remember { mutableStateOf<SessionSummary?>(null) }
    var sessionToRename by remember { mutableStateOf<SessionSummary?>(null) }
    var sessionToMove by remember { mutableStateOf<SessionSummary?>(null) }

    Scaffold(
        topBar = {
            SessionListTopAppBar(
                searchQuery = uiState.searchQuery,
                onSearchQueryChange = viewModel::setSearchQuery,
                onReconnectClick = onReconnectClick,
                onSettingsClick = onSettingsClick,
                onTasksClick = onTasksClick,
                onSkillsClick = onSkillsClick,
                onMemoryClick = onMemoryClick,
                onInsightsClick = onInsightsClick
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    viewModel.createSession { sessionId ->
                        onSessionClick(sessionId)
                    }
                },
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                shape = CircleShape
            ) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = stringResource(R.string.new_session)
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                uiState.isLoading && uiState.sections.isEmpty() -> LoadingPlaceholder()
                uiState.sections.isEmpty() -> EmptyPlaceholder(
                    isSearchActive = uiState.searchQuery.isNotBlank(),
                    errorMessage = uiState.errorMessage,
                    onRefresh = viewModel::refresh,
                    onReconnect = onReconnectClick,
                    onSettings = onSettingsClick
                )
                else -> SessionListContent(
                    sections = uiState.sections,
                    isRefreshing = uiState.isRefreshing,
                    onRefresh = viewModel::refresh,
                    onSessionClick = onSessionClick,
                    onPinToggle = viewModel::togglePinned,
                    onArchive = viewModel::archive,
                    onRestore = viewModel::restore,
                    onDelete = { sessionToDelete = it },
                    onRename = { sessionToRename = it },
                    onDuplicate = viewModel::duplicate,
                    onMove = { sessionToMove = it },
                    isMutating = viewModel::isMutating
                )
            }

            if (uiState.isViewingCachedData) {
                OfflineBanner(modifier = Modifier.align(Alignment.TopCenter))
            }
        }
    }

    sessionToDelete?.let { session ->
        DeleteConfirmationDialog(
            sessionTitle = session.title?.takeIf { it.isNotBlank() }
                ?: stringResource(R.string.untitled_session),
            onConfirm = {
                viewModel.delete(session)
                sessionToDelete = null
            },
            onDismiss = { sessionToDelete = null }
        )
    }

    sessionToRename?.let { session ->
        RenameSessionDialog(
            initialTitle = session.title ?: "",
            onConfirm = { title ->
                viewModel.rename(session, title)
                sessionToRename = null
            },
            onDismiss = { sessionToRename = null }
        )
    }

    sessionToMove?.let { session ->
        MoveToProjectDialog(
            projects = uiState.projects,
            isLoading = uiState.isLoadingProjects,
            currentProjectId = session.projectId,
            onSelect = { projectId ->
                viewModel.moveToProject(session, projectId)
                sessionToMove = null
            },
            onDismiss = { sessionToMove = null },
            onRefresh = viewModel::loadProjects
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionListTopAppBar(
    searchQuery: String,
    onSearchQueryChange: (String) -> Unit,
    onReconnectClick: () -> Unit,
    onSettingsClick: () -> Unit,
    onTasksClick: () -> Unit,
    onSkillsClick: () -> Unit,
    onMemoryClick: () -> Unit,
    onInsightsClick: () -> Unit
) {
    var menuExpanded by remember { mutableStateOf(false) }

    TopAppBar(
        title = { Text(stringResource(R.string.sessions_title)) },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.surface,
            scrolledContainerColor = MaterialTheme.colorScheme.surface
        ),
        navigationIcon = {
            IconButton(onClick = onReconnectClick) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.reconnect)
                )
            }
        },
        actions = {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = onSearchQueryChange,
                placeholder = { Text(stringResource(R.string.search_sessions)) },
                singleLine = true,
                modifier = Modifier
                    .width(180.dp)
                    .heightIn(min = 40.dp)
                    .padding(end = 8.dp),
                shape = RoundedCornerShape(24.dp),
                textStyle = MaterialTheme.typography.bodyMedium
            )

            IconButton(onClick = { menuExpanded = true }) {
                Icon(
                    imageVector = Icons.Default.MoreVert,
                    contentDescription = stringResource(R.string.utilities_menu)
                )
            }

            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false }
            ) {
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Default.Assignment, contentDescription = null) },
                    text = { Text(stringResource(R.string.tasks)) },
                    onClick = { menuExpanded = false; onTasksClick() }
                )
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Default.Build, contentDescription = null) },
                    text = { Text(stringResource(R.string.skills)) },
                    onClick = { menuExpanded = false; onSkillsClick() }
                )
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Default.Memory, contentDescription = null) },
                    text = { Text(stringResource(R.string.memory)) },
                    onClick = { menuExpanded = false; onMemoryClick() }
                )
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Default.TrendingUp, contentDescription = null) },
                    text = { Text(stringResource(R.string.insights)) },
                    onClick = { menuExpanded = false; onInsightsClick() }
                )
                HorizontalDivider()
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    text = { Text(stringResource(R.string.settings)) },
                    onClick = { menuExpanded = false; onSettingsClick() }
                )
            }
        }
    )
}

@OptIn(ExperimentalMaterialApi::class)
@Composable
private fun SessionListContent(
    sections: List<SessionSection>,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    onSessionClick: (String) -> Unit,
    onPinToggle: (SessionSummary) -> Unit,
    onArchive: (SessionSummary) -> Unit,
    onRestore: (SessionSummary) -> Unit,
    onDelete: (SessionSummary) -> Unit,
    onRename: (SessionSummary) -> Unit,
    onDuplicate: (SessionSummary) -> Unit,
    onMove: (SessionSummary) -> Unit,
    isMutating: (SessionSummary) -> Boolean
) {
    val pullState = rememberPullRefreshState(
        refreshing = isRefreshing,
        onRefresh = onRefresh
    )

    Box(modifier = Modifier.pullRefresh(pullState)) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            if (isRefreshing) {
                item(key = "refreshing") {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }
            sections.forEach { section ->
                item(key = "header_${section.kind}") {
                    SectionHeader(title = section.title)
                }

                items(
                    items = section.sessions,
                    key = { it.sessionId ?: it.hashCode().toString() }
                ) { session ->
                    SwipeableSessionRow(
                        session = session,
                        onClick = { session.sessionId?.let(onSessionClick) },
                        onPinToggle = { onPinToggle(session) },
                        onArchive = { onArchive(session) },
                        onRestore = { onRestore(session) },
                        onDelete = { onDelete(session) },
                        onRename = { onRename(session) },
                        onDuplicate = { onDuplicate(session) },
                        onMove = { onMove(session) },
                        isMutating = isMutating(session)
                    )
                }
            }
        }

        PullRefreshIndicator(
            refreshing = isRefreshing,
            state = pullState,
            modifier = Modifier.align(Alignment.TopCenter)
        )
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
    )
}

@OptIn(ExperimentalMaterialApi::class, ExperimentalFoundationApi::class)
@Composable
private fun SwipeableSessionRow(
    session: SessionSummary,
    onClick: () -> Unit,
    onPinToggle: () -> Unit,
    onArchive: () -> Unit,
    onRestore: () -> Unit,
    onDelete: () -> Unit,
    onRename: () -> Unit,
    onDuplicate: () -> Unit,
    onMove: () -> Unit,
    isMutating: Boolean
) {
    val haptic = LocalHapticFeedback.current
    var menuExpanded by remember { mutableStateOf(false) }
    val dismissState = rememberDismissState(
        confirmStateChange = { value ->
            when (value) {
                DismissValue.DismissedToEnd -> onArchive()
                DismissValue.DismissedToStart -> onDelete()
                DismissValue.Default -> Unit
            }
            false
        }
    )

    SwipeToDismiss(
        state = dismissState,
        directions = setOf(DismissDirection.StartToEnd, DismissDirection.EndToStart),
        background = {
            val direction = dismissState.dismissDirection
            val color = when (direction) {
                DismissDirection.StartToEnd -> MaterialTheme.colorScheme.secondaryContainer
                DismissDirection.EndToStart -> MaterialTheme.colorScheme.errorContainer
                null -> MaterialTheme.colorScheme.surface
            }
            val icon = when (direction) {
                DismissDirection.StartToEnd -> Icons.Default.Archive
                DismissDirection.EndToStart -> Icons.Default.Delete
                null -> null
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(color)
                    .padding(horizontal = 20.dp),
                contentAlignment = when (direction) {
                    DismissDirection.StartToEnd -> Alignment.CenterStart
                    DismissDirection.EndToStart -> Alignment.CenterEnd
                    null -> Alignment.Center
                }
            ) {
                icon?.let { Icon(imageVector = it, contentDescription = null) }
            }
        },
        dismissContent = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        onClick = onClick,
                        onLongClick = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            menuExpanded = true
                        }
                    ),
                contentAlignment = Alignment.CenterStart
            ) {
                SessionRow(session = session)
            }
            SessionContextMenu(
                expanded = menuExpanded,
                session = session,
                onDismiss = { menuExpanded = false },
                onPinToggle = { menuExpanded = false; onPinToggle() },
                onArchive = { menuExpanded = false; onArchive() },
                onRestore = { menuExpanded = false; onRestore() },
                onRename = { menuExpanded = false; onRename() },
                onDuplicate = { menuExpanded = false; onDuplicate() },
                onMove = { menuExpanded = false; onMove() },
                onDelete = { menuExpanded = false; onDelete() },
                isMutating = isMutating
            )
        }
    )
}

@Composable
private fun SessionRow(session: SessionSummary) {
    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = session.title?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.untitled_session),
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                if (session.pinned == true) {
                    Spacer(modifier = Modifier.width(6.dp))
                    Icon(
                        imageVector = Icons.Filled.Pin,
                        contentDescription = stringResource(R.string.pinned),
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.primary
                    )
                }
            }
        },
        supportingContent = {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = session.model?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.no_model),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = formatTimestamp(session.lastMessageAt),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        modifier = Modifier.fillMaxWidth(),
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface)
    )
}

@Composable
private fun SessionContextMenu(
    expanded: Boolean,
    session: SessionSummary,
    onDismiss: () -> Unit,
    onPinToggle: () -> Unit,
    onArchive: () -> Unit,
    onRestore: () -> Unit,
    onRename: () -> Unit,
    onDuplicate: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
    isMutating: Boolean
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss
    ) {
        DropdownMenuItem(
            leadingIcon = {
                Icon(
                    Icons.Filled.Pin,
                    contentDescription = null
                )
            },
            text = {
                Text(
                    if (session.pinned == true) stringResource(R.string.unpin)
                    else stringResource(R.string.pin)
                )
            },
            onClick = onPinToggle,
            enabled = !isMutating
        )
        DropdownMenuItem(
            leadingIcon = { Icon(Icons.Default.Archive, contentDescription = null) },
            text = {
                Text(
                    if (session.archived == true) stringResource(R.string.restore)
                    else stringResource(R.string.archive)
                )
            },
            onClick = if (session.archived == true) onRestore else onArchive,
            enabled = !isMutating
        )
        DropdownMenuItem(
            leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
            text = { Text(stringResource(R.string.rename)) },
            onClick = onRename,
            enabled = !isMutating
        )
        DropdownMenuItem(
            leadingIcon = { Icon(Icons.Default.Folder, contentDescription = null) },
            text = { Text(stringResource(R.string.move_to_project)) },
            onClick = onMove,
            enabled = !isMutating
        )
        DropdownMenuItem(
            leadingIcon = { Icon(Icons.Default.Add, contentDescription = null) },
            text = { Text(stringResource(R.string.duplicate)) },
            onClick = onDuplicate,
            enabled = !isMutating
        )
        HorizontalDivider()
        DropdownMenuItem(
            leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null) },
            text = { Text(stringResource(R.string.delete)) },
            onClick = onDelete,
            enabled = !isMutating
        )
    }
}

@Composable
private fun EmptyPlaceholder(
    isSearchActive: Boolean,
    errorMessage: String?,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
    onSettings: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = when {
                errorMessage != null -> stringResource(R.string.sessions_load_failed)
                isSearchActive -> stringResource(R.string.no_search_results)
                else -> stringResource(R.string.no_sessions_yet)
            },
            style = MaterialTheme.typography.titleMedium,
            color = if (errorMessage != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = errorMessage
                ?: if (isSearchActive) stringResource(R.string.try_different_search)
                else stringResource(R.string.tap_plus_to_start),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (!isSearchActive) {
            Spacer(modifier = Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onRefresh) {
                    Text(stringResource(R.string.refresh))
                }
                OutlinedButton(onClick = onReconnect) {
                    Text(stringResource(R.string.reconnect))
                }
            }
            Spacer(modifier = Modifier.height(8.dp))
            TextButton(onClick = onSettings) {
                Text(stringResource(R.string.settings))
            }
        }
    }
}

@Composable
private fun LoadingPlaceholder() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun OfflineBanner(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = stringResource(R.string.offline_cached_data),
            color = MaterialTheme.colorScheme.onErrorContainer,
            style = MaterialTheme.typography.labelLarge
        )
    }
}

@Composable
private fun DeleteConfirmationDialog(
    sessionTitle: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.delete_session_title)) },
        text = {
            Text(stringResource(R.string.delete_session_message, sessionTitle))
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    stringResource(R.string.delete),
                    color = MaterialTheme.colorScheme.error
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        }
    )
}

@Composable
private fun RenameSessionDialog(
    initialTitle: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var title by remember(initialTitle) { mutableStateOf(initialTitle) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename_session)) },
        text = {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text(stringResource(R.string.session_title)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(title.trim()) },
                enabled = title.trim().isNotBlank()
            ) {
                Text(stringResource(R.string.save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        }
    )
}

@Composable
private fun MoveToProjectDialog(
    projects: List<ProjectSummary>,
    isLoading: Boolean,
    currentProjectId: String?,
    onSelect: (String?) -> Unit,
    onDismiss: () -> Unit,
    onRefresh: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.move_to_project)) },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                if (isLoading && projects.isEmpty()) {
                    Box(
                        modifier = Modifier.fillMaxWidth(),
                        contentAlignment = Alignment.Center
                    ) {
                        CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                    }
                } else {
                    TextButton(
                        onClick = { onSelect(null) },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = currentProjectId != null
                    ) {
                        Text(stringResource(R.string.no_project))
                    }
                    projects.forEach { project ->
                        val projectId = project.projectId
                        val selected = currentProjectId == projectId
                        TextButton(
                            onClick = { projectId?.let { onSelect(it) } },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = projectId != null && !selected
                        ) {
                            Text(
                                text = project.name?.takeIf { it.isNotBlank() }
                                    ?: stringResource(R.string.untitled_project),
                                color = if (selected) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                    if (projects.isEmpty()) {
                        TextButton(onClick = onRefresh) {
                            Text(stringResource(R.string.refresh_projects))
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        }
    )
}

private fun formatTimestamp(timestamp: Double?): String {
    if (timestamp == null || timestamp <= 0) return ""
    val instant = Instant.ofEpochSecond(timestamp.toLong())
    val date = Date.from(instant)
    val now = Calendar.getInstance()
    val messageCal = Calendar.getInstance().apply { time = date }

    return when {
        isSameDay(now, messageCal) -> SimpleDateFormat("h:mm a", Locale.getDefault()).format(date)
        isYesterday(now, messageCal) -> "Yesterday"
        now.get(Calendar.YEAR) == messageCal.get(Calendar.YEAR) -> SimpleDateFormat(
            "MMM d",
            Locale.getDefault()
        ).format(date)

        else -> SimpleDateFormat("MMM d, yyyy", Locale.getDefault()).format(date)
    }
}

private fun isSameDay(cal1: Calendar, cal2: Calendar): Boolean {
    return cal1.get(Calendar.YEAR) == cal2.get(Calendar.YEAR) &&
        cal1.get(Calendar.DAY_OF_YEAR) == cal2.get(Calendar.DAY_OF_YEAR)
}

private fun isYesterday(now: Calendar, other: Calendar): Boolean {
    val yesterday = now.clone() as Calendar
    yesterday.add(Calendar.DAY_OF_YEAR, -1)
    return yesterday.get(Calendar.YEAR) == other.get(Calendar.YEAR) &&
        yesterday.get(Calendar.DAY_OF_YEAR) == other.get(Calendar.DAY_OF_YEAR)
}
