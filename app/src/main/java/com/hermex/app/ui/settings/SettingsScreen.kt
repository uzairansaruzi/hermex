package com.hermex.app.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.model.ModelsResponse
import com.hermex.app.data.model.ProfilesResponse
import com.hermex.app.data.model.SettingsResponse
import com.hermex.app.data.network.ApiClient
import com.hermex.app.ui.components.HermexAlertDialog
import com.hermex.app.ui.components.HermexCard
import com.hermex.app.ui.components.HermexModelPickerSheet
import com.hermex.app.ui.components.HermexProfilePickerSheet
import com.hermex.app.ui.components.HermexSectionHeader
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val apiClient: ApiClient,
    val authManager: AuthManager
) : ViewModel() {
    private val _settings = MutableStateFlow<SettingsResponse?>(null)
    val settings: StateFlow<SettingsResponse?> = _settings.asStateFlow()

    private val _models = MutableStateFlow<ModelsResponse?>(null)
    val models: StateFlow<ModelsResponse?> = _models.asStateFlow()

    private val _profiles = MutableStateFlow<ProfilesResponse?>(null)
    val profiles: StateFlow<ProfilesResponse?> = _profiles.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isActionLoading = MutableStateFlow(false)
    val isActionLoading: StateFlow<Boolean> = _isActionLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _showModelDialog = MutableStateFlow(false)
    val showModelDialog: StateFlow<Boolean> = _showModelDialog.asStateFlow()

    private val _showProfileDialog = MutableStateFlow(false)
    val showProfileDialog: StateFlow<Boolean> = _showProfileDialog.asStateFlow()

    init { loadSettings() }

    fun loadSettings() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _settings.value = apiClient.settings()
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun showModelDialog() {
        _showModelDialog.value = true
        viewModelScope.launch {
            try {
                _models.value = apiClient.models()
            } catch (e: Exception) {
                _error.value = e.message
            }
        }
    }

    fun dismissModelDialog() {
        _showModelDialog.value = false
    }

    fun selectModel(model: String) {
        _isActionLoading.value = true
        viewModelScope.launch {
            try {
                apiClient.defaultModel(model)
                _showModelDialog.value = false
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isActionLoading.value = false
            }
        }
    }

    fun showProfileDialog() {
        _showProfileDialog.value = true
        viewModelScope.launch {
            try {
                _profiles.value = apiClient.profiles()
            } catch (e: Exception) {
                _error.value = e.message
            }
        }
    }

    fun dismissProfileDialog() {
        _showProfileDialog.value = false
    }

    fun selectProfile(profile: String) {
        _isActionLoading.value = true
        viewModelScope.launch {
            try {
                apiClient.profileSwitch(profile)
                _showProfileDialog.value = false
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isActionLoading.value = false
            }
        }
    }

    fun signOut(onComplete: () -> Unit) {
        viewModelScope.launch {
            try {
                apiClient.logout()
            } catch (_: Exception) {
                // Proceed with local sign-out even if server logout fails.
            }
            authManager.clearAuth()
            onComplete()
        }
    }

    fun dismissError() {
        _error.value = null
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onSignOut: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val settings by viewModel.settings.collectAsState()
    val models by viewModel.models.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isActionLoading by viewModel.isActionLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val showModelDialog by viewModel.showModelDialog.collectAsState()
    val showProfileDialog by viewModel.showProfileDialog.collectAsState()
    val appVersion = remember { "1.0.0" }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.loadSettings() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                else -> {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp)
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            HermexSectionHeader("Server")
                            SettingsInfoCard(
                                serverUrl = viewModel.authManager.serverUrl.orEmpty(),
                                serverVersion = settings?.webuiVersion.orEmpty(),
                                appVersion = appVersion
                            )
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            HermexSectionHeader("Agent")
                            HermexCard(modifier = Modifier.fillMaxWidth()) {
                                SettingsActionRow(
                                    label = "Change Model",
                                    onClick = { viewModel.showModelDialog() }
                                )
                                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
                                SettingsActionRow(
                                    label = "Switch Profile",
                                    onClick = { viewModel.showProfileDialog() }
                                )
                            }
                        }
                        TextButton(
                            onClick = { viewModel.signOut(onSignOut) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                        ) {
                            Text("Sign Out", style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
        }
    }

    if (showModelDialog) {
        HermexModelPickerSheet(
            models = models,
            currentModelId = models?.defaultModel,
            isLoading = isActionLoading,
            onSelect = { modelId, _ -> viewModel.selectModel(modelId) },
            onDismiss = { viewModel.dismissModelDialog() },
        )
    }

    if (showProfileDialog) {
        HermexProfilePickerSheet(
            profiles = profiles?.profiles.orEmpty(),
            activeProfileName = profiles?.activeProfile,
            isLoading = isActionLoading,
            onSelect = { it.name?.let { name -> viewModel.selectProfile(name) } },
            onDismiss = { viewModel.dismissProfileDialog() },
        )
    }

    error?.let {
        HermexAlertDialog(
            onDismissRequest = { viewModel.dismissError() },
            confirmButton = {
                TextButton(onClick = { viewModel.dismissError() }) { Text("OK") }
            },
            title = { Text("Error") },
            text = { Text(it) },
        )
    }
}

@Composable
private fun SettingsInfoCard(serverUrl: String, serverVersion: String, appVersion: String) {
    HermexCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            InfoRow(label = "Server URL", value = serverUrl.takeIf { it.isNotBlank() } ?: "Not configured")
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            InfoRow(label = "Server Version", value = serverVersion.takeIf { it.isNotBlank() } ?: "Unknown")
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            InfoRow(label = "App Version", value = appVersion)
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun SettingsActionRow(label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

