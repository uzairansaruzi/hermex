package com.hermexapp.android.features.panels

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
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
import com.hermexapp.android.model.CronJob
import com.hermexapp.android.ui.CircleButton
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.StatusBadge
import com.hermexapp.android.ui.theme.LocalHermexPalette

enum class PanelKind(val title: String) {
    TASKS("Tasks"),
    SKILLS("Skills"),
    MEMORY("Memory"),
    INSIGHTS("Insights"),
}

@Composable
fun PanelScreen(kind: PanelKind, viewModel: PanelsViewModel, onClose: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    val palette = LocalHermexPalette.current

    fun reload() = when (kind) {
        PanelKind.TASKS -> viewModel.loadTasks()
        PanelKind.SKILLS -> viewModel.loadSkills()
        PanelKind.MEMORY -> viewModel.loadMemory()
        PanelKind.INSIGHTS -> viewModel.loadInsights()
    }

    LaunchedEffect(kind) { reload() }
    BackHandler {
        if (state.openSkill != null) viewModel.closeSkill() else onClose()
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = palette.canvas,
        topBar = {
            HermexHeader(
                title = state.openSkill?.name ?: kind.title,
                onBack = {
                    if (state.openSkill != null) viewModel.closeSkill() else onClose()
                },
                actions = {
                    CircleButton(onClick = { reload() }, icon = Icons.Filled.Refresh, size = 40)
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            state.errorMessage?.let {
                Column(modifier = Modifier.padding(horizontal = 16.dp)) {
                    Text(it, color = palette.destructive, style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { reload() }) { Text("Retry") }
                }
            }
            state.noticeMessage?.let {
                Text(
                    it,
                    modifier = Modifier.padding(horizontal = 16.dp),
                    color = palette.accent,
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            if (state.isLoading) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = palette.accent)
                }
                return@Column
            }

            when {
                state.openSkill != null -> SkillDetail(state.openSkill!!)
                kind == PanelKind.TASKS -> TasksPanel(state, viewModel)
                kind == PanelKind.SKILLS -> SkillsPanel(state, viewModel)
                kind == PanelKind.MEMORY -> MemoryPanel(state)
                kind == PanelKind.INSIGHTS -> InsightsPanel(state)
            }
        }
    }
}

/** The iOS Tasks screen: "Running now" card, "Scheduled Jobs" header, job cards. */
@Composable
private fun TasksPanel(state: PanelsViewModel.UiState, viewModel: PanelsViewModel) {
    val palette = LocalHermexPalette.current
    val runningCount = state.cronJobs.count { it.state == "running" }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Surface(color = palette.card, shape = MaterialTheme.shapes.large) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("⚡", style = MaterialTheme.typography.titleSmall)
                    Text("Running now", style = MaterialTheme.typography.titleSmall)
                    androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                    Text(
                        "$runningCount",
                        style = MaterialTheme.typography.titleSmall,
                        color = palette.textSecondary,
                    )
                }
            }
        }

        item {
            Text(
                "Scheduled Jobs",
                style = MaterialTheme.typography.titleMedium,
                color = palette.textSecondary,
                modifier = Modifier.padding(top = 8.dp),
            )
        }

        if (state.cronJobs.isEmpty()) {
            item { CenteredNote("No scheduled tasks on this server.") }
        } else {
            items(state.cronJobs, key = { it.stableId }) { job ->
                CronJobCard(job, viewModel)
            }
        }
    }
}

@Composable
private fun CronJobCard(job: CronJob, viewModel: PanelsViewModel) {
    val palette = LocalHermexPalette.current
    val paused = job.enabled == false || job.state == "paused"

    Surface(color = palette.card, shape = MaterialTheme.shapes.large) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    job.name ?: job.jobId ?: "Task",
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                StatusBadge(
                    text = if (paused) "Paused" else (job.state ?: "Active"),
                    color = if (paused) palette.warning else palette.success,
                )
            }

            job.prompt?.takeIf { it.isNotBlank() }?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = palette.textSecondary,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            KeyValueRow("Schedule", job.scheduleDisplay)
            KeyValueRow("Last", job.lastStatus)
            KeyValueRow("Model", job.model)
            KeyValueRow("Profile", job.profile)
            job.lastError?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = palette.destructive)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                val id = job.jobId
                if (id != null) {
                    TextButton(onClick = { viewModel.runCronJob(id) }) {
                        Text("Run now", color = palette.accent)
                    }
                    if (paused) {
                        TextButton(onClick = { viewModel.resumeCronJob(id) }) { Text("Resume") }
                    } else {
                        TextButton(onClick = { viewModel.pauseCronJob(id) }) { Text("Pause") }
                    }
                }
            }
        }
    }
}

@Composable
private fun KeyValueRow(label: String, value: String?) {
    if (value.isNullOrBlank()) return
    val palette = LocalHermexPalette.current
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = palette.textSecondary,
            modifier = Modifier.width(80.dp),
        )
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun SkillsPanel(state: PanelsViewModel.UiState, viewModel: PanelsViewModel) {
    val palette = LocalHermexPalette.current
    if (state.skills.isEmpty()) {
        CenteredNote("No skills installed on this server.")
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(state.skills, key = { it.name ?: it.path ?: it.hashCode().toString() }) { skill ->
            Surface(
                color = palette.card,
                shape = MaterialTheme.shapes.large,
                onClick = { skill.name?.let(viewModel::openSkill) },
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(skill.name ?: "Skill", style = MaterialTheme.typography.titleSmall)
                        skill.category?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.labelSmall,
                                color = palette.accent,
                            )
                        }
                    }
                    skill.description?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = palette.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SkillDetail(skill: com.hermexapp.android.model.SkillDetailResponse) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        Text(
            skill.content ?: "This skill has no readable content.",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun MemoryPanel(state: PanelsViewModel.UiState) {
    val palette = LocalHermexPalette.current
    val memory = state.memory
    if (memory == null || (memory.memory.isNullOrBlank() && memory.user.isNullOrBlank() && memory.soul.isNullOrBlank())) {
        CenteredNote("No agent memory recorded yet.")
        return
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        MemorySection("Memory", memory.memory, palette.card)
        MemorySection("User", memory.user, palette.card)
        MemorySection("Soul", memory.soul, palette.card)
    }
}

@Composable
private fun MemorySection(title: String, content: String?, cardColor: androidx.compose.ui.graphics.Color) {
    if (content.isNullOrBlank()) return
    Surface(color = cardColor, shape = MaterialTheme.shapes.large) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(content, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
        }
    }
}

@Composable
private fun InsightsPanel(state: PanelsViewModel.UiState) {
    val palette = LocalHermexPalette.current
    val insights = state.insights
    if (insights == null) {
        CenteredNote("No usage data for this period.")
        return
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Surface(color = palette.card, shape = MaterialTheme.shapes.large) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "Last ${insights.periodDays ?: 30} days",
                    style = MaterialTheme.typography.titleSmall,
                )
                StatRow("Sessions", insights.totalSessions?.toString())
                StatRow("Messages", insights.totalMessages?.toString())
                StatRow("Tokens", insights.totalTokens?.let { formatCount(it) })
                StatRow("Cost", insights.totalCost?.let { "$%.2f".format(it) })
            }
        }
        if (!insights.models.isNullOrEmpty()) {
            Surface(color = palette.card, shape = MaterialTheme.shapes.large) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("By model", style = MaterialTheme.typography.titleSmall)
                    insights.models.forEach { model ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(
                                model.model ?: "?",
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                listOfNotNull(
                                    model.totalTokens?.let(::formatCount),
                                    model.cost?.let { "$%.2f".format(it) },
                                ).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                                color = palette.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatRow(label: String, value: String?) {
    val palette = LocalHermexPalette.current
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = palette.textSecondary)
        Text(value ?: "—", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun CenteredNote(message: String) {
    val palette = LocalHermexPalette.current
    Box(Modifier.fillMaxWidth().padding(vertical = 48.dp), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = palette.textSecondary,
            modifier = Modifier.padding(24.dp),
        )
    }
}

private fun formatCount(value: Int): String = when {
    value >= 1_000_000 -> "%.1fM".format(value / 1_000_000.0)
    value >= 1_000 -> "%.1fk".format(value / 1_000.0)
    else -> value.toString()
}
