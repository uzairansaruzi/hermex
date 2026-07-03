package com.hermexapp.android.features.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hermexapp.android.config.AppPrefs
import com.hermexapp.android.ui.HermexHeader
import com.hermexapp.android.ui.theme.LocalHermexPalette
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
            HorizontalDivider()

            Button(onClick = onSignOut, modifier = Modifier.fillMaxWidth()) {
                Text("Sign out")
            }
        }
    }

    if (showModelPicker) {
        AlertDialog(
            onDismissRequest = { showModelPicker = false },
            confirmButton = { TextButton(onClick = { showModelPicker = false }) { Text("Cancel") } },
            title = { Text("Default model") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    modelGroups.flatMap { it.models }.take(30).forEach { option ->
                        Text(
                            option.displayName,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    showModelPicker = false
                                    scope.launch {
                                        try {
                                            val response = client.saveDefaultModel(option.id)
                                            currentDefaultModel = response.model ?: option.id
                                            message = "Default model saved."
                                        } catch (e: ApiError) {
                                            message = e.userMessage
                                        }
                                    }
                                }
                                .padding(vertical = 10.dp),
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall)
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
