package com.hermex.app.ui.insights

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.model.SessionSummary
import com.hermex.app.data.model.SessionsResponse
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class InsightsViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _sessions = MutableStateFlow<SessionsResponse?>(null)
    val sessions: StateFlow<SessionsResponse?> = _sessions.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    init { loadSessions() }

    fun loadSessions() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _sessions.value = apiClient.sessions()
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    data class Totals(
        val inputTokens: Long = 0,
        val outputTokens: Long = 0,
        val estimatedCost: Double = 0.0
    )

    val totals: Totals
        get() = _sessions.value?.sessions.orEmpty().fold(Totals()) { acc, session ->
            Totals(
                inputTokens = acc.inputTokens + (session.inputTokens ?: 0L),
                outputTokens = acc.outputTokens + (session.outputTokens ?: 0L),
                estimatedCost = acc.estimatedCost + (session.estimatedCost ?: 0.0)
            )
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InsightsScreen(onBack: () -> Unit, viewModel: InsightsViewModel = hiltViewModel()) {
    val sessionsResponse by viewModel.sessions.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val totals = remember(sessionsResponse) { viewModel.totals }
    val sessions = sessionsResponse?.sessions.orEmpty()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Insights") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.loadSessions() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                error != null -> ErrorState(message = error.orEmpty(), onRetry = { viewModel.loadSessions() })
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        item {
                            SummaryCard(totals = totals)
                        }
                        item {
                            Text("Per session", style = MaterialTheme.typography.titleMedium)
                        }
                        if (sessions.isEmpty()) {
                            item {
                                Text(
                                    "No sessions available",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        } else {
                            items(sessions, key = { it.sessionId.orEmpty() }) { session ->
                                SessionUsageCard(session = session)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SummaryCard(totals: InsightsViewModel.Totals) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Usage summary", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(12.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                SummaryItem(label = "Input", value = formatTokens(totals.inputTokens))
                SummaryItem(label = "Output", value = formatTokens(totals.outputTokens))
                SummaryItem(label = "Est. cost", value = "%.4f".format(totals.estimatedCost))
            }
        }
    }
}

@Composable
private fun SummaryItem(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = MaterialTheme.typography.titleMedium)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SessionUsageCard(session: SessionSummary) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(session.title.orEmpty().takeIf { it.isNotBlank() } ?: "Untitled", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Input: ${formatTokens(session.inputTokens ?: 0L)}", style = MaterialTheme.typography.bodySmall)
                Text("Output: ${formatTokens(session.outputTokens ?: 0L)}", style = MaterialTheme.typography.bodySmall)
                Text("Cost: %.4f".format(session.estimatedCost ?: 0.0), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

private fun formatTokens(value: Long): String {
    return when {
        value >= 1_000_000 -> "%.1fM".format(value / 1_000_000.0)
        value >= 1_000 -> "%.1fk".format(value / 1_000.0)
        else -> value.toString()
    }
}

@Composable
private fun ErrorState(message: String, onRetry: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text("Error: $message", color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(12.dp))
        FilledTonalButton(onClick = onRetry) { Text("Retry") }
    }
}
