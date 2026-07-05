package com.hermexapp.android.features.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.config.AccentPreset
import com.hermexapp.android.config.AppPrefs
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.HermexPickerSheet
import com.hermexapp.android.ui.PickerRow
import com.hermexapp.android.ui.PickerSection
import com.hermexapp.android.ui.theme.LocalHermexPalette
import com.hermexapp.android.ui.theme.accentColorFromHex
import com.hermexapp.android.config.ThemeChoice
import com.hermexapp.android.model.ModelCatalogGroup
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.defaultModel
import com.hermexapp.android.network.models
import com.hermexapp.android.network.saveDefaultModel
import com.hermexapp.android.network.serverSettings
import kotlinx.coroutines.launch

/** Phase 8 settings: server info, default model, theme, sign out. */
@Composable
fun SettingsScreen(
    client: ApiClient,
    prefs: AppPrefs,
    serverUrl: String,
    onSignOut: () -> Unit,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var serverVersion by remember { mutableStateOf<String?>(null) }
    var botName by remember { mutableStateOf<String?>(null) }
    var currentDefaultModel by remember { mutableStateOf<String?>(null) }
    var modelGroups by remember { mutableStateOf<List<ModelCatalogGroup>>(emptyList()) }
    var showModelPicker by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val theme by prefs.theme.collectAsState()
    val accent by prefs.accent.collectAsState()
    val expandThinking by prefs.expandThinking.collectAsState()
    val expandTools by prefs.expandTools.collectAsState()
    val notificationsEnabled by prefs.notificationsEnabled.collectAsState()

    LaunchedEffect(Unit) {
        runCatching { client.serverSettings() }.getOrNull()?.let {
            serverVersion = it.webuiVersion ?: it.version
            botName = it.botName
        }
        runCatching { client.defaultModel() }.getOrNull()?.let { currentDefaultModel = it.model }
        runCatching { client.models() }.getOrNull()?.let { modelGroups = it.catalogGroups }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = LocalHermexPalette.current.canvas,
        topBar = { HermexHeader(title = "Settings", onBack = onClose) },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            message?.let {
                Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall)
            }

            SectionTitle("Server")
            InfoRow("URL", serverUrl)
            InfoRow("Agent", botName ?: "—")
            InfoRow("hermes-webui", serverVersion ?: "—")
            HorizontalDivider()

            SectionTitle("Default model")
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showModelPicker = true },
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Model", style = MaterialTheme.typography.bodyMedium)
                Text(
                    currentDefaultModel ?: "Server default",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            HorizontalDivider()

            SectionTitle("Appearance")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ThemeChoice.entries.forEach { choice ->
                    FilterChip(
                        selected = theme == choice,
                        onClick = { prefs.setTheme(choice) },
                        label = { Text(choice.name.lowercase().replaceFirstChar { it.uppercase() }) },
                    )
                }
            }

            Text(
                "Header Logo Color",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 4.dp),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AccentPreset.entries.forEach { preset ->
                    val selected = accent == preset
                    Box(
                        modifier = Modifier
                            .size(if (selected) 34.dp else 28.dp)
                            .clip(CircleShape)
                            .background(accentColorFromHex(preset.hex))
                            .clickable { prefs.setAccent(preset) },
                    )
                }
            }
            HorizontalDivider()

            SectionTitle("Chat display")
            ToggleRow("Expand thinking by default", expandThinking) { prefs.setExpandThinking(it) }
            ToggleRow("Expand tool calls by default", expandTools) { prefs.setExpandTools(it) }
            HorizontalDivider()

            SectionTitle("Notifications")
            ToggleRow("Notify when a response completes", notificationsEnabled) {
                prefs.setNotificationsEnabled(it)
            }
            HorizontalDivider()

            Button(onClick = onSignOut, modifier = Modifier.fillMaxWidth()) {
                Text("Sign out")
            }
        }
    }

    if (showModelPicker) {
        HermexPickerSheet(
            title = "Default model",
            sections = modelGroups.map { group ->
                PickerSection(
                    header = group.name,
                    rows = group.models.map { PickerRow(it.displayName, it.id) },
                )
            },
            isSelected = { it == currentDefaultModel },
            onPick = { modelId ->
                showModelPicker = false
                scope.launch {
                    try {
                        val response = client.saveDefaultModel(modelId)
                        currentDefaultModel = response.model ?: modelId
                        message = "Default model saved."
                    } catch (e: ApiError) {
                        message = e.userMessage
                    }
                }
            },
            onDismiss = { showModelPicker = false },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall)
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
