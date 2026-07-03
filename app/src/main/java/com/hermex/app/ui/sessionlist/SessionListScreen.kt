package com.hermex.app.ui.sessionlist

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Pin
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Construction
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
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
import com.hermex.app.ui.components.HermexAvatar
import com.hermex.app.ui.theme.HermexTheme
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
        floatingActionButton = {
            NewChatCapsuleButton(
                onClick = {
                    viewModel.createSession { sessionId ->
                        onSessionClick(sessionId)
                    }
                }
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            HermexHomeHeader(
                searchQuery = uiState.searchQuery,
                onSearchQueryChange = viewModel::setSearchQuery,
                onReconnectClick = onReconnectClick,
                onSettingsClick = onSettingsClick,
                onTasksClick = onTasksClick,
                onSkillsClick = onSkillsClick,
                onMemoryClick = onMemoryClick,
                onInsightsClick = onInsightsClick
            )

            Box(modifier = Modifier.weight(1f)) {
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

/**
 * Home header mirroring the iOS session list: gold Hermes wordmark, capsule
 * search chrome, gold initials avatar, then flat utility nav rows (Tasks,
 * Skills, Memory, Insights) and a bold "Sessions" section title.
 */
@Composable
private fun HermexHomeHeader(
    searchQuery: String,
    onSearchQueryChange: (String) -> Unit,
    onReconnectClick: () -> Unit,
    onSettingsClick: () -> Unit,
    onTasksClick: () -> Unit,
    onSkillsClick: () -> Unit,
    onMemoryClick: () -> Unit,
    onInsightsClick: () -> Unit
) {
    var searchExpanded by rememberSaveable { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 24.dp, end = 16.dp, top = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineMedium,
                color = HermexTheme.colors.themeGold
            )
            Spacer(modifier = Modifier.weight(1f))
            IconButton(onClick = onReconnectClick) {
                Icon(
                    imageVector = Icons.Outlined.Sync,
                    contentDescription = stringResource(R.string.reconnect),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)
            ) {
                IconButton(
                    onClick = {
                        searchExpanded = !searchExpanded
                        if (!searchExpanded) onSearchQueryChange("")
                    }
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Search,
                        contentDescription = stringResource(R.string.search_sessions),
                        tint = MaterialTheme.colorScheme.onSurface
                    )
                }
            }
            Spacer(modifier = Modifier.width(10.dp))
            Box(
                modifier = Modifier.clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onSettingsClick
                )
            ) {
                HermexAvatar(initials = "H")
            }
        }

        if (searchExpanded) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = onSearchQueryChange,
                placeholder = { Text(stringResource(R.string.search_sessions)) },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 8.dp),
                shape = RoundedCornerShape(24.dp),
                textStyle = MaterialTheme.typography.bodyMedium,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                    focusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                    unfocusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)
                )
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        UtilityNavRow(Icons.Outlined.Schedule, stringResource(R.string.tasks), onTasksClick)
        UtilityNavRow(Icons.Outlined.Construction, stringResource(R.string.skills), onSkillsClick)
        UtilityNavRow(Icons.Outlined.Psychology, stringResource(R.string.memory), onMemoryClick)
        UtilityNavRow(Icons.Outlined.BarChart, stringResource(R.string.insights), onInsightsClick)

        Text(
            text = stringResource(R.string.sessions_title),
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.padding(start = 24.dp, top = 20.dp, bottom = 4.dp)
        )
    }
}

/** Flat sidebar-style nav row: icon in a fixed slot + semibold label. */
@Composable
private fun UtilityNavRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .heightIn(min = 44.dp)
            .padding(horizontal = 24.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        Box(modifier = Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(22.dp)
            )
        }
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

/**
 * Monochrome capsule "Chat" action mirroring the iOS floating new-chat
 * button: black-on-white in dark mode, white-on-black in light mode.
 */
@Composable
private fun NewChatCapsuleButton(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = HermexTheme.colors.monochrome,
        contentColor = HermexTheme.colors.onMonochrome,
        shadowElevation = 8.dp,
        modifier = Modifier.height(58.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 22.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = Icons.Outlined.Edit,
                contentDescription = stringResource(R.string.new_session),
                modifier = Modifier.size(20.dp)
            )
            Text(
                text = stringResource(R.string.chat_fab_label),
                style = MaterialTheme.typography.titleMedium
            )
        }
    }
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
        text = title.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 8.dp)
    )
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
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
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> onArchive()
                SwipeToDismissBoxValue.EndToStart -> onDelete()
                SwipeToDismissBoxValue.Settled -> Unit
            }
            false
        }
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = true,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            val direction = dismissState.dismissDirection
            val color = when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> MaterialTheme.colorScheme.secondaryContainer
                SwipeToDismissBoxValue.EndToStart -> MaterialTheme.colorScheme.errorContainer
                SwipeToDismissBoxValue.Settled -> MaterialTheme.colorScheme.surface
            }
            val icon = when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> Icons.Default.Archive
                SwipeToDismissBoxValue.EndToStart -> Icons.Default.Delete
                SwipeToDismissBoxValue.Settled -> null
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(color)
                    .padding(horizontal = 20.dp),
                contentAlignment = when (direction) {
                    SwipeToDismissBoxValue.StartToEnd -> Alignment.CenterStart
                    SwipeToDismissBoxValue.EndToStart -> Alignment.CenterEnd
                    SwipeToDismissBoxValue.Settled -> Alignment.Center
                }
            ) {
                icon?.let { Icon(imageVector = it, contentDescription = null) }
            }
        }
    ) {
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
}

@Composable
private fun SessionRow(session: SessionSummary) {
    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = session.title?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.untitled_session),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
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
    val warning = HermexTheme.colors.warning
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(warning.copy(alpha = 0.12f))
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = stringResource(R.string.offline_cached_data),
            color = MaterialTheme.colorScheme.onSurface,
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
