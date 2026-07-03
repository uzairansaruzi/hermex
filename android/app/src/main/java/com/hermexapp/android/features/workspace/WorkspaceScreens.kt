package com.hermexapp.android.features.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.ui.CircleButton
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.theme.LocalHermexPalette

@Composable
fun FileBrowserScreen(viewModel: WorkspaceViewModel, onClose: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    val palette = LocalHermexPalette.current

    LaunchedEffect(Unit) {
        if (state.entries.isEmpty() && !state.isLoading) viewModel.loadDirectory(null, push = false)
    }
    BackHandler {
        if (state.openFile != null) viewModel.closeFile()
        else if (!viewModel.navigateUp()) onClose()
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = palette.canvas,
        topBar = {
            HermexHeader(
                title = state.openFile?.name ?: state.currentPath?.substringAfterLast('/') ?: "Files",
                subtitle = state.currentPath,
                onBack = {
                    if (state.openFile != null) viewModel.closeFile()
                    else if (!viewModel.navigateUp()) onClose()
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            state.errorMessage?.let {
                Text(
                    it,
                    modifier = Modifier.padding(16.dp),
                    color = LocalHermexPalette.current.destructive,
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            val file = state.openFile
            when {
                state.isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }

                file != null -> Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .horizontalScroll(rememberScrollState()),
                ) {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(file.content.orEmpty().lines()) { line ->
                            Text(
                                line,
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                modifier = Modifier.padding(horizontal = 12.dp),
                                softWrap = false,
                            )
                        }
                    }
                }

                state.entries.isEmpty() -> EmptyPanel("This directory is empty.")

                else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(state.entries, key = { it.stableId }) { entry ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    val path = entry.path ?: return@clickable
                                    if (entry.isBrowsableDirectory) viewModel.loadDirectory(path)
                                    else viewModel.openFile(path)
                                }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(if (entry.isBrowsableDirectory) "📁" else "📄")
                            Text(
                                entry.name ?: entry.path ?: "?",
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

@Composable
fun GitScreen(viewModel: WorkspaceViewModel, onClose: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    val palette = LocalHermexPalette.current

    LaunchedEffect(Unit) { viewModel.loadGit() }
    BackHandler {
        if (state.openDiff != null) viewModel.closeDiff() else onClose()
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = palette.canvas,
        topBar = {
            HermexHeader(
                title = state.openDiff?.path ?: "Git",
                subtitle = state.gitStatus?.branch,
                onBack = {
                    if (state.openDiff != null) viewModel.closeDiff() else onClose()
                },
                actions = {
                    CircleButton(onClick = { viewModel.loadGit() }, icon = Icons.Filled.Refresh, size = 40)
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            state.errorMessage?.let {
                Text(
                    it,
                    modifier = Modifier.padding(16.dp),
                    color = LocalHermexPalette.current.destructive,
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            val diff = state.openDiff
            val status = state.gitStatus
            when {
                state.isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }

                diff != null -> DiffView(diff)

                status == null || status.isGit == false ->
                    EmptyPanel("This session's workspace is not a git repository.")

                else -> GitStatusList(status, viewModel)
            }
        }
    }
}

@Composable
private fun GitStatusList(status: com.hermexapp.android.model.GitStatus, viewModel: WorkspaceViewModel) {
    val files = status.files.orEmpty()
    Column(modifier = Modifier.fillMaxSize()) {
        Text(
            buildString {
                append(status.branch ?: "detached")
                status.upstream?.let { append(" → $it") }
                status.ahead?.takeIf { it > 0 }?.let { append("  ↑$it") }
                status.behind?.takeIf { it > 0 }?.let { append("  ↓$it") }
            },
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.titleSmall,
        )
        HorizontalDivider()
        if (files.isEmpty()) {
            EmptyPanel("Working tree clean.")
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(files, key = { it.stableId }) { file ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                file.path?.let { viewModel.openDiff(it, file.staged) }
                            }
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            "${file.status ?: "M"}  ${file.path ?: "?"}",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            "+${file.additions ?: 0} −${file.deletions ?: 0}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun DiffView(diff: com.hermexapp.android.model.GitDiff) {
    when {
        diff.binary == true -> EmptyPanel("Binary file — no text diff.")
        diff.tooLarge == true -> EmptyPanel("This diff is too large to display (server cap).")
        else -> Column(modifier = Modifier.fillMaxSize().horizontalScroll(rememberScrollState())) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(diff.diff.orEmpty().lines()) { line ->
                    val color = when {
                        line.startsWith("+") && !line.startsWith("+++") ->
                            MaterialTheme.colorScheme.primary
                        line.startsWith("-") && !line.startsWith("---") ->
                            MaterialTheme.colorScheme.error
                        line.startsWith("@@") -> MaterialTheme.colorScheme.tertiary
                        else -> MaterialTheme.colorScheme.onSurface
                    }
                    Text(
                        line,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = color,
                        modifier = Modifier.padding(horizontal = 12.dp),
                        softWrap = false,
                    )
                }
            }
        }
    }
}

@Composable
internal fun EmptyPanel(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(24.dp),
        )
    }
}
