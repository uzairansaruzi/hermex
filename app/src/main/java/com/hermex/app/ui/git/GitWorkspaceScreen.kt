package com.hermex.app.ui.git

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import com.hermex.app.data.model.GitBranchesResponse
import com.hermex.app.data.model.GitDiffResponse
import com.hermex.app.data.model.GitStatusResponse
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class GitWorkspaceViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _sessionId = MutableStateFlow("")
    val sessionId: StateFlow<String> = _sessionId.asStateFlow()

    private val _status = MutableStateFlow<GitStatusResponse?>(null)
    val status: StateFlow<GitStatusResponse?> = _status.asStateFlow()

    private val _branches = MutableStateFlow<GitBranchesResponse?>(null)
    val branches: StateFlow<GitBranchesResponse?> = _branches.asStateFlow()

    private val _diff = MutableStateFlow<GitDiffResponse?>(null)
    val diff: StateFlow<GitDiffResponse?> = _diff.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun initialize(sessionId: String) {
        if (_sessionId.value == sessionId) return
        _sessionId.value = sessionId
        loadAll()
    }

    fun loadAll() {
        if (_sessionId.value.isBlank()) return
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _status.value = apiClient.gitStatus(_sessionId.value)
                _branches.value = apiClient.gitBranches(_sessionId.value)
                _diff.value = apiClient.gitDiff(_sessionId.value)
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun dismissError() {
        _error.value = null
    }

}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GitWorkspaceScreen(
    sessionId: String,
    onBack: () -> Unit,
    viewModel: GitWorkspaceViewModel = hiltViewModel()
) {
    val status by viewModel.status.collectAsState()
    val branches by viewModel.branches.collectAsState()
    val diff by viewModel.diff.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val scroll = rememberScrollState()

    LaunchedEffect(sessionId) { viewModel.initialize(sessionId) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Git") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.loadAll() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                error != null && status == null -> ErrorState(message = error.orEmpty(), onRetry = { viewModel.loadAll() })
                else -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(scroll)
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        StatusCard(status = status)
                        BranchRow(
                            currentBranch = status?.branch
                        )
                        DiffCard(diff = diff)
                    }
                }
            }
        }
    }

    error?.let {
        AlertDialog(
            onDismissRequest = { viewModel.dismissError() },
            confirmButton = { TextButton(onClick = { viewModel.dismissError() }) { Text("OK") } },
            title = { Text("Error") },
            text = { Text(it) }
        )
    }
}

@Composable
private fun StatusCard(status: GitStatusResponse?) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Branch", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(status?.branch ?: "Unknown", style = MaterialTheme.typography.bodyLarge)
            }
            HorizontalDivider()
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                StatusCount(label = "Modified", count = status?.modifiedCount ?: 0)
                StatusCount(label = "Staged", count = status?.stagedCount ?: 0)
                StatusCount(label = "Untracked", count = status?.untrackedCount ?: 0)
            }
        }
    }
}

@Composable
private fun StatusCount(label: String, count: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(count.toString(), style = MaterialTheme.typography.titleMedium)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BranchRow(currentBranch: String?) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text("Current branch: ${currentBranch ?: "Unknown"}", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun DiffCard(diff: GitDiffResponse?) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .padding(16.dp)
                .fillMaxWidth()
        ) {
            Text("Diff", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            val scroll = rememberScrollState()
            Column(modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(scroll)) {
                Text(
                    diff?.diff?.takeIf { it.isNotBlank() } ?: "No diff",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
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
