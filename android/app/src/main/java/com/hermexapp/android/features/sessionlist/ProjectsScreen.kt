package com.hermexapp.android.features.sessionlist

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.config.AccentPreset
import com.hermexapp.android.model.Project
import com.hermexapp.android.model.SessionSummary
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.theme.LocalHermexPalette
import com.hermexapp.android.ui.theme.accentColorFromHex

/**
 * Projects (folders) screen: lists the profile's projects with a color dot and
 * session count, expands to that project's sessions, and supports create /
 * rename / delete. Mirrors the iOS Projects sheet.
 */
@Composable
fun ProjectsScreen(
    viewModel: SessionListViewModel,
    onOpenSession: (String) -> Unit,
    onClose: () -> Unit,
) {
    val state by viewModel.uiState.collectAsState()
    val palette = LocalHermexPalette.current
    var editTarget by remember { mutableStateOf<Project?>(null) }
    var deleteTarget by remember { mutableStateOf<Project?>(null) }
    var showCreate by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf<String?>(null) }

    // Sessions with no project appear under a synthetic "No project" group.
    val byProject = remember(state.sessions) { state.sessions.groupBy { it.projectId } }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = palette.canvas,
        topBar = {
            HermexHeader(
                title = "Projects",
                onBack = onClose,
                actions = {
                    TextButton(onClick = { showCreate = true }) { Text("New") }
                },
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(innerPadding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp),
        ) {
            if (state.projects.isEmpty()) {
                item {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("No projects yet", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Tap New to group sessions into a project.",
                            style = MaterialTheme.typography.bodySmall,
                            color = palette.textSecondary,
                        )
                    }
                }
            }

            items(state.projects, key = { it.projectId ?: it.name.orEmpty() }) { project ->
                val sessions = byProject[project.projectId].orEmpty()
                ProjectRow(
                    project = project,
                    sessionCount = sessions.size,
                    onClick = { expanded = if (expanded == project.projectId) null else project.projectId },
                    onEdit = { editTarget = project },
                    onDelete = { deleteTarget = project },
                )
                if (expanded == project.projectId) {
                    sessions.forEach { session ->
                        ProjectSessionRow(session) { session.sessionId?.let(onOpenSession) }
                    }
                }
            }

            val unfiled = byProject[null].orEmpty()
            if (unfiled.isNotEmpty()) {
                item {
                    Text(
                        "No project",
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                        style = MaterialTheme.typography.titleSmall,
                        color = palette.textSecondary,
                    )
                }
                items(unfiled, key = { it.stableId }) { session ->
                    ProjectSessionRow(session) { session.sessionId?.let(onOpenSession) }
                }
            }
        }
    }

    if (showCreate) {
        ProjectEditDialog(
            initialName = "",
            initialColor = null,
            titleText = "New project",
            onDismiss = { showCreate = false },
            onConfirm = { name, color ->
                viewModel.createProject(name, color)
                showCreate = false
            },
        )
    }

    editTarget?.let { project ->
        ProjectEditDialog(
            initialName = project.name.orEmpty(),
            initialColor = project.color,
            titleText = "Edit project",
            onDismiss = { editTarget = null },
            onConfirm = { name, color ->
                project.projectId?.let { viewModel.renameProject(it, name, color) }
                editTarget = null
            },
        )
    }

    deleteTarget?.let { project ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete project?") },
            text = {
                Text("\"${project.name ?: "Untitled"}\" will be removed. Its sessions are kept and un-filed.")
            },
            confirmButton = {
                TextButton(onClick = {
                    project.projectId?.let(viewModel::deleteProject)
                    deleteTarget = null
                }) { Text("Delete", color = palette.destructive) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ProjectRow(
    project: Project,
    sessionCount: Int,
    onClick: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = LocalHermexPalette.current
    val dot = project.color?.let { accentColorFromHex(it) } ?: palette.accent
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(14.dp).background(dot, CircleShape))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                project.name?.ifBlank { null } ?: "Untitled",
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "$sessionCount ${if (sessionCount == 1) "session" else "sessions"}",
                style = MaterialTheme.typography.bodySmall,
                color = palette.textSecondary,
            )
        }
        TextButton(onClick = onEdit) { Text("Edit") }
        TextButton(onClick = onDelete) { Text("Delete", color = palette.destructive) }
    }
}

@Composable
private fun ProjectSessionRow(session: SessionSummary, onClick: () -> Unit) {
    val palette = LocalHermexPalette.current
    Text(
        session.title?.ifBlank { null } ?: "Untitled session",
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = 46.dp, end = 20.dp, top = 8.dp, bottom = 8.dp),
        style = MaterialTheme.typography.bodyMedium,
        color = palette.textSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** Name field + color-preset dots, shared by New and Edit. */
@Composable
private fun ProjectEditDialog(
    initialName: String,
    initialColor: String?,
    titleText: String,
    onDismiss: () -> Unit,
    onConfirm: (name: String, color: String?) -> Unit,
) {
    val palette = LocalHermexPalette.current
    var name by remember { mutableStateOf(initialName) }
    var color by remember { mutableStateOf(initialColor) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(titleText) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    label = { Text("Name") },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    AccentPreset.entries.forEach { preset ->
                        val selected = color == preset.hex
                        Box(
                            modifier = Modifier
                                .size(if (selected) 30.dp else 24.dp)
                                .background(accentColorFromHex(preset.hex), CircleShape)
                                .clickable { color = preset.hex },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.trim(), color) },
                enabled = name.isNotBlank(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
