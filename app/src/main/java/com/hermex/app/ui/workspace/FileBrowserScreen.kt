package com.hermex.app.ui.workspace

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.model.FileContentResponse
import com.hermex.app.data.model.WorkspaceEntry
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class FileBrowserViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _sessionId = MutableStateFlow("")
    val sessionId: StateFlow<String> = _sessionId.asStateFlow()

    private val _pathStack = MutableStateFlow(listOf(""))
    val pathStack: StateFlow<List<String>> = _pathStack.asStateFlow()

    private val _entries = MutableStateFlow<List<WorkspaceEntry>>(emptyList())
    val entries: StateFlow<List<WorkspaceEntry>> = _entries.asStateFlow()

    private val _fileContent = MutableStateFlow<FileContentResponse?>(null)
    val fileContent: StateFlow<FileContentResponse?> = _fileContent.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isFileLoading = MutableStateFlow(false)
    val isFileLoading: StateFlow<Boolean> = _isFileLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _fileError = MutableStateFlow<String?>(null)
    val fileError: StateFlow<String?> = _fileError.asStateFlow()

    fun initialize(sessionId: String) {
        if (_sessionId.value == sessionId) return
        _sessionId.value = sessionId
        _pathStack.value = listOf("")
        _fileContent.value = null
        _fileError.value = null
        loadFiles()
    }

    fun loadFiles() {
        if (_sessionId.value.isBlank()) return
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _entries.value = apiClient.listFiles(_sessionId.value, _pathStack.value.last())
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun navigateInto(folderName: String) {
        val currentPath = _pathStack.value.last()
        val newPath = if (currentPath.isEmpty()) folderName else "$currentPath/$folderName"
        _pathStack.value = _pathStack.value + newPath
        loadFiles()
    }

    fun navigateToBreadcrumb(index: Int) {
        if (index < _pathStack.value.lastIndex) {
            _pathStack.value = _pathStack.value.take(index + 1)
            loadFiles()
        }
    }

    fun openFile(entry: WorkspaceEntry) {
        val path = entry.path ?: return
        _isFileLoading.value = true
        _fileError.value = null
        viewModelScope.launch {
            try {
                _fileContent.value = apiClient.fileContent(_sessionId.value, path)
            } catch (e: Exception) {
                _fileContent.value = FileContentResponse(path = path)
                _fileError.value = e.message
            } finally {
                _isFileLoading.value = false
            }
        }
    }

    fun closeFilePreview() {
        _fileContent.value = null
        _fileError.value = null
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileBrowserScreen(
    sessionId: String,
    onBack: () -> Unit,
    viewModel: FileBrowserViewModel = hiltViewModel()
) {
    val entries by viewModel.entries.collectAsState()
    val pathStack by viewModel.pathStack.collectAsState()
    val fileContent by viewModel.fileContent.collectAsState()
    val fileError by viewModel.fileError.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isFileLoading by viewModel.isFileLoading.collectAsState()
    val error by viewModel.error.collectAsState()

    LaunchedEffect(sessionId) { viewModel.initialize(sessionId) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Files") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.loadFiles() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                error != null -> ErrorState(message = error.orEmpty(), onRetry = { viewModel.loadFiles() })
                else -> {
                    Column(modifier = Modifier.fillMaxSize()) {
                        BreadcrumbBar(pathStack = pathStack, onSegmentClick = viewModel::navigateToBreadcrumb)
                        if (entries.isEmpty()) {
                            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text("This folder is empty", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        } else {
                            LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
                                items(entries, key = { it.path.orEmpty() }) { entry ->
                                    FileEntryRow(entry = entry, onClick = {
                                        if (entry.type == "directory") {
                                            viewModel.navigateInto(entry.name.orEmpty())
                                        } else {
                                            viewModel.openFile(entry)
                                        }
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fileContent?.let { content ->
        FilePreviewDialog(
            path = content.path.orEmpty(),
            text = content.content,
            isLoading = isFileLoading,
            error = fileError,
            onDismiss = { viewModel.closeFilePreview() }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BreadcrumbBar(pathStack: List<String>, onSegmentClick: (Int) -> Unit) {
    SingleChoiceSegmentedButtonRow(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        pathStack.forEachIndexed { index, path ->
            val label = if (path.isEmpty()) "Root" else path.substringAfterLast('/')
            SegmentedButton(
                selected = index == pathStack.lastIndex,
                onClick = { onSegmentClick(index) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = pathStack.size)
            ) {
                Text(label, maxLines = 1)
            }
        }
    }
}

@Composable
private fun FileEntryRow(entry: WorkspaceEntry, onClick: () -> Unit) {
    val isDirectory = entry.type == "directory"
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        headlineContent = { Text(entry.name.orEmpty()) },
        leadingContent = {
            Icon(
                imageVector = if (isDirectory) Icons.Default.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                contentDescription = if (isDirectory) "Folder" else "File",
                tint = if (isDirectory) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
            )
        },
        supportingContent = {
            val info = buildList {
                add(entry.type?.replaceFirstChar { it.uppercase() } ?: "File")
                entry.size?.let { add(formatBytes(it)) }
            }.joinToString(" • ")
            Text(info, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FilePreviewDialog(
    path: String,
    text: String?,
    isLoading: Boolean,
    error: String?,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 200.dp, max = 480.dp)
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Text(path.substringAfterLast('/'), style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(12.dp))
            if (isLoading) {
                CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
            } else {
                val scroll = rememberScrollState()
                Column(modifier = Modifier.fillMaxWidth().verticalScroll(scroll)) {
                    Text(
                        error ?: text?.takeIf { it.isNotBlank() } ?: "No preview available",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
                    )
                }
            }
        }
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    return "%.1f GB".format(mb / 1024.0)
}

@Composable
private fun ErrorState(message: String, onRetry: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text("Error: $message", color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(12.dp))
        FilledTonalButton(onClick = onRetry) { Text("Retry") }
    }
}
