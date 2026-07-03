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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.model.*
import com.hermex.app.data.network.ApiClient
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

    private val _jobOutputs = MutableStateFlow<List<CronOutput>>(emptyList())
    val jobOutputs: StateFlow<List<CronOutput>> = _jobOutputs.asStateFlow()

    init { loadJobs() }

    fun loadJobs() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val response = apiClient.crons()
                _jobs.value = response.crons ?: emptyList()
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
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Text("Error: $error", color = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.height(8.dp))
                        FilledTonalButton(onClick = { viewModel.loadJobs() }) { Text("Retry") }
                    }
                }
                jobs.isEmpty() -> {
                    Text(
                        "No scheduled tasks",
                        modifier = Modifier.align(Alignment.Center),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(jobs, key = { it.jobId ?: it.name ?: "" }) { job ->
                            CronJobCard(job = job, onClick = { viewModel.selectJob(job) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun CronJobCard(job: CronJob, onClick: () -> Unit) {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (job.enabled == true) Icons.Default.Schedule else Icons.Default.PauseCircle,
                    contentDescription = null,
                    tint = if (job.enabled == true) MaterialTheme.colorScheme.primary
                           else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    job.name ?: job.jobId ?: "Unnamed",
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }
            Spacer(Modifier.height(4.dp))
            job.schedule?.let {
                Text("Schedule: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            job.prompt?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailScreen(job: CronJob, outputs: List<CronOutput>, onDismiss: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(job.name ?: job.jobId ?: "Task Detail") },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    job.schedule?.let { DetailRow("Schedule", it) }
                    job.deliver?.let { DetailRow("Delivery", it) }
                    DetailRow("Enabled", if (job.enabled == true) "Yes" else "No")
                    job.lastRunAt?.let { DetailRow("Last Run", formatTimestamp(it)) }
                    job.nextRunAt?.let { DetailRow("Next Run", formatTimestamp(it)) }
                    job.error?.let { DetailRow("Error", it) }
                }
            }
            item {
                job.prompt?.let {
                    Text("Prompt", style = MaterialTheme.typography.titleSmall)
                    Spacer(Modifier.height(4.dp))
                    ElevatedCard { Text(it, modifier = Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium) }
                }
            }
            if (job.skills?.isNotEmpty() == true) {
                item {
                    Text("Skills", style = MaterialTheme.typography.titleSmall)
                    job.skills!!.forEach { skill -> Text("• $skill", style = MaterialTheme.typography.bodySmall) }
                }
            }
            if (outputs.isNotEmpty()) {
                item { Text("Recent Output", style = MaterialTheme.typography.titleSmall) }
                items(outputs) { output ->
                    ElevatedCard {
                        Column(modifier = Modifier.padding(12.dp)) {
                            output.timestamp?.let { Text(formatTimestamp(it), style = MaterialTheme.typography.labelSmall) }
                            Text(output.output ?: "", style = MaterialTheme.typography.bodySmall)
                            output.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DetailRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 2.dp)) {
        Text("$label: ", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

private fun formatTimestamp(ts: Double): String {
    return try {
        SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()).format(Date((ts * 1000).toLong()))
    } catch (_: Exception) { "$ts" }
}
