package com.hermex.app.ui.skills

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
import javax.inject.Inject

@HiltViewModel
class SkillsViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {
    private val _skills = MutableStateFlow<Map<String, List<SkillSummary>>>(emptyMap())
    val skills: StateFlow<Map<String, List<SkillSummary>>> = _skills.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _selectedSkill = MutableStateFlow<SkillSummary?>(null)
    val selectedSkill: StateFlow<SkillSummary?> = _selectedSkill.asStateFlow()

    private val _skillContent = MutableStateFlow<SkillContentResponse?>(null)
    val skillContent: StateFlow<SkillContentResponse?> = _skillContent.asStateFlow()

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    init { loadSkills() }

    fun loadSkills() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val response = apiClient.skills()
                _skills.value = response.skills.orEmpty()
                    .filter { it.disabled != true }
                    .groupBy { it.category?.takeIf(String::isNotBlank) ?: "General" }
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun selectSkill(skill: SkillSummary?) {
        _selectedSkill.value = skill
        if (skill != null) {
            viewModelScope.launch {
                try {
                    _skillContent.value = apiClient.skillContent(skill.name ?: return@launch)
                } catch (_: Exception) {}
            }
        }
    }

    fun updateSearch(query: String) { _searchQuery.value = query }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillsScreen(
    onBack: () -> Unit,
    viewModel: SkillsViewModel = hiltViewModel()
) {
    val skills by viewModel.skills.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val selectedSkill by viewModel.selectedSkill.collectAsState()
    val skillContent by viewModel.skillContent.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()

    if (selectedSkill != null && skillContent != null) {
        SkillDetailScreen(
            skill = selectedSkill!!,
            content = skillContent!!,
            onBack = { viewModel.selectSkill(null) }
        )
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Skills") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } }
            )
        }
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { viewModel.updateSearch(it) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search skills...") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                singleLine = true
            )

            Box(modifier = Modifier.fillMaxSize()) {
                when {
                    isLoading && skills.isEmpty() -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                    error != null -> {
                        Column(modifier = Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Error: $error", color = MaterialTheme.colorScheme.error)
                            Spacer(Modifier.height(8.dp))
                            FilledTonalButton(onClick = { viewModel.loadSkills() }) { Text("Retry") }
                        }
                    }
                    else -> {
                        val filtered = skills.mapValues { (_, skillList) ->
                            skillList.filter {
                                searchQuery.isBlank() ||
                                it.name?.contains(searchQuery, ignoreCase = true) == true ||
                                it.description?.contains(searchQuery, ignoreCase = true) == true
                            }
                        }.filter { it.value.isNotEmpty() }

                        LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(16.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            filtered.toSortedMap().forEach { (category, skillList) ->
                                item {
                                    Text(
                                        category,
                                        style = MaterialTheme.typography.titleSmall,
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(vertical = 8.dp)
                                    )
                                }
                                items(skillList) { skill ->
                                    ListItem(
                                        headlineContent = { Text(skill.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                        supportingContent = { skill.description?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) } },
                                        modifier = Modifier.clickable { viewModel.selectSkill(skill) }
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillDetailScreen(skill: SkillSummary, content: SkillContentResponse, onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(skill.name ?: "Skill") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            item {
                skill.description?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }
                skill.version?.let { Text("v$it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                skill.author?.let { Text("by $it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            item {
                content.content?.let {
                    Spacer(Modifier.height(8.dp))
                    ElevatedCard { Text(it, modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium) }
                }
            }
            content.linkedFiles?.let { files ->
                if (files.isNotEmpty()) {
                    item { Text("Linked Files", style = MaterialTheme.typography.titleSmall) }
                    items(files.entries.toList()) { (name, _) ->
                        ListItem(
                            headlineContent = { Text(name) },
                            leadingContent = { Icon(Icons.Default.InsertDriveFile, contentDescription = null) }
                        )
                    }
                }
            }
        }
    }
}
