package com.hermex.app.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.model.ModelGroup
import com.hermex.app.data.model.ModelOption
import com.hermex.app.data.model.ModelsResponse
import com.hermex.app.data.model.ProfilesResponse
import com.hermex.app.data.model.SettingsResponse
import com.hermex.app.data.network.ApiClient
import com.hermex.app.ui.components.HermexCard
import com.hermex.app.ui.components.HermexSectionHeader
import com.hermex.app.ui.theme.HermexTheme
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
        ModelPickerSheet(
            models = models,
            currentModel = models?.defaultModel,
            isLoading = isActionLoading,
            onSelect = { viewModel.selectModel(it) },
            onDismiss = { viewModel.dismissModelDialog() }
        )
    }

    if (showProfileDialog) {
        ProfilePickerSheet(
            profiles = profiles,
            isLoading = isActionLoading,
            onSelect = { viewModel.selectProfile(it) },
            onDismiss = { viewModel.dismissProfileDialog() }
        )
    }

    error?.let {
        AlertDialog(
            onDismissRequest = { viewModel.dismissError() },
            confirmButton = {
                TextButton(onClick = { viewModel.dismissError() }) { Text("OK") }
            },
            title = { Text("Error") },
            text = { Text(it) }
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelPickerSheet(
    models: ModelsResponse?,
    currentModel: String?,
    isLoading: Boolean,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var searchQuery by remember { mutableStateOf("") }
    val groups = models?.groups.orEmpty()
    val flatFallback = models?.modelsByProvider()?.entries?.toList().orEmpty()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainer
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .heightIn(max = 500.dp)
        ) {
            Text(
                "Change Model",
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(bottom = 12.dp)
            )

            // Search field
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search models") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(Icons.Default.Close, contentDescription = "Clear")
                        }
                    }
                },
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 12.dp),
                singleLine = true
            )

            if (groups.isEmpty() && flatFallback.isEmpty() && isLoading) {
                Box(modifier = Modifier.fillMaxWidth().height(120.dp)) {
                    CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    contentPadding = PaddingValues(bottom = 32.dp)
                ) {
                    if (groups.isNotEmpty()) {
                        groups.forEach { group ->
                            val provider = group.providerId ?: group.provider ?: "Other"
                            val filteredModels = group.models.orEmpty().filter { model ->
                                val id = model.id ?: ""
                                val label = model.label ?: ""
                                searchQuery.isBlank() ||
                                    id.contains(searchQuery, ignoreCase = true) ||
                                    label.contains(searchQuery, ignoreCase = true) ||
                                    provider.contains(searchQuery, ignoreCase = true)
                            }
                            if (filteredModels.isNotEmpty()) {
                                item {
                                    HermexSectionHeader(
                                        text = provider,
                                        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)
                                    )
                                }
                                items(filteredModels) { model ->
                                    ModelRow(
                                        model = model,
                                        isSelected = model.id == currentModel,
                                        onClick = { model.id?.let(onSelect) }
                                    )
                                }
                            }
                        }
                    } else {
                        // Flat fallback (older server without groups)
                        flatFallback.forEach { (provider, modelIds) ->
                            val filtered = modelIds.filter {
                                searchQuery.isBlank() || it.contains(searchQuery, ignoreCase = true)
                            }
                            if (filtered.isNotEmpty()) {
                                item {
                                    HermexSectionHeader(
                                        text = provider,
                                        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)
                                    )
                                }
                                items(filtered) { id ->
                                    ModelRow(
                                        model = ModelOption(id = id, label = null),
                                        isSelected = id == currentModel,
                                        onClick = { onSelect(id) }
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

@Composable
private fun ModelRow(model: ModelOption, isSelected: Boolean, onClick: () -> Unit) {
    val id = model.id ?: return
    val displayName = model.label?.takeIf { it.isNotBlank() } ?: extractModelName(id)
    val showSecondaryId = model.label != null && model.label != id

    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = if (isSelected) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
        else MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (isSelected) {
                Icon(
                    Icons.Default.Check,
                    contentDescription = "Selected",
                    tint = HermexTheme.colors.themeGold,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(Modifier.width(8.dp))
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = displayName,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                    maxLines = 1
                )
                if (showSecondaryId || id.startsWith("@custom:")) {
                    Text(
                        text = id,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

/** Extracts a human-readable model name from a provider-prefixed id. */
private fun extractModelName(id: String): String {
    // "@provider:model-name" or "provider/model-name" → "model-name"
    val afterColon = id.substringAfterLast(':')
    val afterSlash = afterColon.substringAfterLast('/')
    return afterSlash.ifBlank { id }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfilePickerSheet(
    profiles: ProfilesResponse?,
    isLoading: Boolean,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val items = profiles?.profiles?.mapNotNull { it.name }.orEmpty()
    val activeProfile = profiles?.activeProfile

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        containerColor = MaterialTheme.colorScheme.surfaceContainer
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .heightIn(max = 400.dp)
        ) {
            Text(
                "Switch Profile",
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(bottom = 12.dp)
            )

            if (items.isEmpty() && isLoading) {
                Box(modifier = Modifier.fillMaxWidth().height(120.dp)) {
                    CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                }
            } else if (items.isEmpty()) {
                Text(
                    "No profiles available",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 24.dp)
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(bottom = 32.dp)
                ) {
                    items(items) { name ->
                        val isSelected = name == activeProfile
                        Surface(
                            onClick = { onSelect(name) },
                            shape = RoundedCornerShape(12.dp),
                            color = if (isSelected) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
                            else MaterialTheme.colorScheme.surfaceContainer,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 44.dp)
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 12.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                if (isSelected) {
                                    Icon(
                                        Icons.Default.Check,
                                        contentDescription = "Selected",
                                        tint = HermexTheme.colors.themeGold,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(Modifier.width(8.dp))
                                }
                                Text(
                                    text = name,
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
