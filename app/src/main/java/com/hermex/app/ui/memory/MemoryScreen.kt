package com.hermex.app.ui.memory

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Notes
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
import com.hermex.app.ui.components.HermexCard
import com.hermex.app.ui.components.HermexEmptyState
import com.hermex.app.ui.components.HermexErrorState
import com.hermex.app.ui.components.HermexSectionHeader
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
                    HermexErrorState(
                        message = error ?: "Unknown error",
                        onRetry = { viewModel.loadMemory() },
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
                memory != null -> {
                    val hasContent = !memory!!.notes.isNullOrBlank() || !memory!!.userProfile.isNullOrBlank()
                    if (!hasContent) {
                        HermexEmptyState(
                            icon = Icons.Default.Notes,
                            title = "No Memory",
                            description = "Notes and profile data will appear here",
                            modifier = Modifier.align(Alignment.Center)
                        )
                    } else {
                        Column(
                            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(16.dp)
                        ) {
                            if (!memory!!.notes.isNullOrBlank()) {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    HermexSectionHeader("Notes")
                                    HermexCard(modifier = Modifier.fillMaxWidth()) {
                                        Text(
                                            memory!!.notes!!,
                                            style = MaterialTheme.typography.bodyMedium
                                        )
                                    }
                                }
                            }
                            if (!memory!!.userProfile.isNullOrBlank()) {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    HermexSectionHeader("User Profile")
                                    HermexCard(modifier = Modifier.fillMaxWidth()) {
                                        Text(
                                            memory!!.userProfile!!,
                                            style = MaterialTheme.typography.bodyMedium
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
