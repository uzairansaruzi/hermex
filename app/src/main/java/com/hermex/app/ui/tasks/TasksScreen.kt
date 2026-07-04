package com.hermex.app.ui.tasks

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.model.*
import com.hermex.app.data.network.ApiClient
import com.hermex.app.ui.components.HermexCard
import com.hermex.app.ui.components.HermexEmptyState
import com.hermex.app.ui.components.HermexErrorState
import com.hermex.app.ui.components.HermexStatusPill
import com.hermex.app.ui.theme.HermexColors
import com.hermex.app.ui.theme.HermexTheme
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

@HiltViewModel
class TasksViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _jobs = MutableStateFlow<List<CronJob>>(emptyList())
    val jobs: StateFlow<List<CronJob>> = _jobs.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _selectedJob = MutableStateFlow<CronJob?>(null)
    val selectedJob: StateFlow<CronJob?> = _selectedJob.asStateFlow()

    private val _jobOutputs = MutableStateFlow<List<CronOutputItem>>(emptyList())
    val jobOutputs: StateFlow<List<CronOutputItem>> = _jobOutputs.asStateFlow()

    private val _runningJobs = MutableStateFlow<Map<String, Double>>(emptyMap())
    val runningJobs: StateFlow<Map<String, Double>> = _runningJobs.asStateFlow()

    init { loadJobs() }

    fun loadJobs() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val response = apiClient.crons()
                _jobs.value = response.jobList()
                // Also fetch running status
                try {
                    val status = apiClient.cronStatus()
                    _runningJobs.value = status.running?.jobs ?: emptyMap()
                } catch (_: Exception) {}
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun selectJob(job: CronJob?) {
        _selectedJob.value = job
        if (job != null) {
            viewModelScope.launch {
                try {
                    val output = apiClient.cronOutput(job.jobId ?: return@launch)
                    _jobOutputs.value = output.outputs ?: emptyList()
                } catch (_: Exception) {}
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TasksScreen(
    onBack: () -> Unit,
    viewModel: TasksViewModel = hiltViewModel()
) {
    val jobs by viewModel.jobs.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val selectedJob by viewModel.selectedJob.collectAsState()
    val jobOutputs by viewModel.jobOutputs.collectAsState()
    val runningJobs by viewModel.runningJobs.collectAsState()

    if (selectedJob != null) {
        TaskDetailScreen(
            job = selectedJob!!,
            outputs = jobOutputs,
            onDismiss = { viewModel.selectJob(null) }
        )
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Tasks") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.loadJobs() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                isLoading && jobs.isEmpty() -> {
                    CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                }
                error != null -> {
                    HermexErrorState(
                        message = error ?: "Unknown error",
                        onRetry = { viewModel.loadJobs() },
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
                jobs.isEmpty() -> {
                    HermexEmptyState(
                        icon = Icons.Default.Schedule,
                        title = "No Tasks",
                        description = "Scheduled tasks will appear here",
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        // Running-now banner
                        if (runningJobs.isNotEmpty()) {
                            item {
                                RunningNowBanner(count = runningJobs.size)
                            }
                        }

                        items(jobs, key = { it.jobId ?: it.name ?: "" }) { job ->
                            val jobId = job.jobId
                            val isRunning = jobId != null && runningJobs.containsKey(jobId)
                            CronJobCard(
                                job = job,
                                isRunning = isRunning,
                                elapsed = if (isRunning && jobId != null) runningJobs[jobId] else null,
                                onClick = { viewModel.selectJob(job) }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RunningNowBanner(count: Int) {
    HermexCard(
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                Icons.Default.ElectricBolt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp)
            )
            Text(
                "Running now",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.weight(1f)
            )
            Text(
                "$count",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun CronJobCard(job: CronJob, isRunning: Boolean, elapsed: Double?, onClick: () -> Unit) {
    HermexCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        // Title row + status pill
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = job.displayName,
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(8.dp))
            val (statusText, statusColor) = when {
                isRunning -> "Running" to MaterialTheme.colorScheme.primary
                else -> when (job.status) {
                    CronJobStatus.ACTIVE -> "Active" to HermexTheme.colors.success
                    CronJobStatus.PAUSED -> "Paused" to HermexTheme.colors.warning
                    CronJobStatus.OFF -> "Off" to HermexTheme.colors.warning
                    CronJobStatus.ERROR -> "Error" to MaterialTheme.colorScheme.error
                    CronJobStatus.NEEDS_ATTENTION -> "Attention" to HermexTheme.colors.themeGold
                }
            }
            HermexStatusPill(text = statusText, tint = statusColor)
        }

        // Prompt preview
        job.prompt?.let { prompt ->
            Spacer(Modifier.height(6.dp))
            Text(
                text = prompt,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
        }

        // Metadata rows
        Spacer(Modifier.height(8.dp))
        job.scheduleText?.let {
            MetadataRow("Schedule", it, mono = true)
        }
        job.nextRunAt?.let {
            MetadataRow("Next", formatTimestamp(it))
        }
        job.lastRunAt?.let {
            MetadataRow("Last", formatTimestamp(it))
        }
        if (isRunning && elapsed != null) {
            MetadataRow("Elapsed", "${elapsed.toLong()}s")
        }
        job.deliver?.let {
            MetadataRow("Deliver", it)
        }
        job.model?.let {
            MetadataRow("Model", it)
        }
        job.errorText?.let {
            MetadataRow("Error", it, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun MetadataRow(
    label: String,
    value: String,
    mono: Boolean = false,
    color: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onSurface
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 1.dp)
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(64.dp)
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall.let {
                if (mono) it.copy(fontFamily = FontFamily.Monospace) else it
            },
            color = color,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailScreen(job: CronJob, outputs: List<CronOutputItem>, onDismiss: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(job.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(vertical = 12.dp)
        ) {
            // Metadata card
            item {
                HermexCard(modifier = Modifier.fillMaxWidth()) {
                    job.scheduleText?.let { MetadataRow("Schedule", it, mono = true) }
                    job.deliver?.let { MetadataRow("Deliver", it) }
                    MetadataRow("Enabled", if (job.enabled == true) "Yes" else "No")
                    job.lastRunAt?.let { MetadataRow("Last Run", formatTimestamp(it)) }
                    job.nextRunAt?.let { MetadataRow("Next Run", formatTimestamp(it)) }
                    job.model?.let { MetadataRow("Model", it) }
                    job.profile?.let { MetadataRow("Profile", it) }
                    job.errorText?.let {
                        MetadataRow("Error", it, color = MaterialTheme.colorScheme.error)
                    }
                }
            }

            // Prompt
            job.prompt?.let { prompt ->
                item {
                    Text(
                        "Prompt",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                    Spacer(Modifier.height(4.dp))
                    HermexCard(modifier = Modifier.fillMaxWidth()) {
                        Text(prompt, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }

            // Skills
            if (job.skills?.isNotEmpty() == true) {
                item {
                    Text(
                        "Skills",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                    Spacer(Modifier.height(4.dp))
                    job.skills!!.forEach { skill ->
                        Text(
                            "  $skill",
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                        )
                    }
                }
            }

            // Outputs
            if (outputs.isNotEmpty()) {
                item {
                    Text(
                        "Recent Output",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
                items(outputs) { output ->
                    HermexCard(modifier = Modifier.fillMaxWidth()) {
                        output.filename?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(Modifier.height(4.dp))
                        }
                        Text(
                            output.content ?: "",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            } else {
                item {
                    HermexEmptyState(
                        icon = Icons.Default.Description,
                        title = "No Output",
                        description = "This task hasn't produced output yet",
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }
    }
}

private fun formatTimestamp(ts: Double): String {
    return try {
        SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()).format(Date((ts * 1000).toLong()))
    } catch (_: Exception) { "$ts" }
}
