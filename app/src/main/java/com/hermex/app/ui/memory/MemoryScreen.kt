package com.hermex.app.ui.memory

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
import com.hermex.app.data.model.MemoryResponse
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MemoryViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _memory = MutableStateFlow<MemoryResponse?>(null)
    val memory: StateFlow<MemoryResponse?> = _memory.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    init { loadMemory() }

    fun loadMemory() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try { _memory.value = apiClient.memory() }
            catch (e: Exception) { _error.value = e.message }
            finally { _isLoading.value = false }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryScreen(onBack: () -> Unit, viewModel: MemoryViewModel = hiltViewModel()) {
    val memory by viewModel.memory.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Memory") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
                actions = { IconButton(onClick = { viewModel.loadMemory() }) { Icon(Icons.Default.Refresh, contentDescription = "Refresh") } }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                error != null -> {
                    Column(modifier = Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("Error: $error", color = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.height(8.dp))
                        FilledTonalButton(onClick = { viewModel.loadMemory() }) { Text("Retry") }
                    }
                }
                memory != null -> {
                    Column(
                        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Text("My Notes", style = MaterialTheme.typography.titleMedium)
                        ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                memory!!.notes?.takeIf { it.isNotBlank() } ?: "No notes",
                                modifier = Modifier.padding(16.dp),
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (memory!!.notes.isNullOrBlank()) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
                            )
                        }
                        HorizontalDivider()
                        Text("User Profile", style = MaterialTheme.typography.titleMedium)
                        ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                memory!!.userProfile?.takeIf { it.isNotBlank() } ?: "No profile data",
                                modifier = Modifier.padding(16.dp),
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (memory!!.userProfile.isNullOrBlank()) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                }
            }
        }
    }
}
