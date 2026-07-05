package com.hermexapp.android.features.sessionlist

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermexapp.android.model.SessionSummary
import com.hermexapp.android.network.ApiError
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class SessionListViewModel(
    private val repository: SessionRepository,
    private val onAuthError: (Throwable) -> Unit = {},
) : ViewModel() {

    data class UiState(
        val sessions: List<SessionSummary> = emptyList(),
        val projects: List<com.hermexapp.android.model.Project> = emptyList(),
        val searchQuery: String = "",
        val isLoading: Boolean = false,
        val isFromCache: Boolean = false,
        val errorMessage: String? = null,
    )

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private var searchJob: Job? = null

    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    suspend fun refreshNow() {
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        try {
            val result = repository.loadSessions()
            _uiState.update {
                it.copy(sessions = result.sessions, isFromCache = result.fromCache, isLoading = false)
            }
        } catch (e: ApiError) {
            onAuthError(e)
            _uiState.update { it.copy(errorMessage = e.userMessage, isLoading = false) }
        }
        // Projects are best-effort: never block or error the session list on them.
        runCatching { repository.loadProjects() }.getOrNull()?.let { projects ->
            _uiState.update { it.copy(projects = projects) }
        }
    }

    fun updateSearchQuery(query: String) {
        _uiState.update { it.copy(searchQuery = query) }
        searchJob?.cancel()
        if (query.isBlank()) {
            refresh()
            return
        }
        searchJob = viewModelScope.launch {
            delay(300) // debounce typing before hitting the server
            searchNow(query)
        }
    }

    suspend fun searchNow(query: String) {
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        try {
            val sessions = repository.search(query)
            _uiState.update { it.copy(sessions = sessions, isFromCache = false, isLoading = false) }
        } catch (e: ApiError) {
            onAuthError(e)
            _uiState.update { it.copy(errorMessage = e.userMessage, isLoading = false) }
        }
    }

    /** Creates a session on the server and returns its id for navigation. */
    suspend fun createSessionNow(): String? = try {
        val created = repository.createSession()
        refreshNow()
        created?.sessionId
    } catch (e: ApiError) {
        onAuthError(e)
        _uiState.update { it.copy(errorMessage = e.userMessage) }
        null
    }

    fun renameSession(id: String, title: String) = mutate { repository.renameSession(id, title) }

    fun deleteSession(id: String) = mutate { repository.deleteSession(id) }

    fun pinSession(id: String, pinned: Boolean) = mutate { repository.pinSession(id, pinned) }

    fun archiveSession(id: String, archived: Boolean) =
        mutate { repository.archiveSession(id, archived) }

    fun moveSession(id: String, projectId: String?) = mutate { repository.moveSession(id, projectId) }

    /** Duplicates a session server-side; returns the copy's id for navigation. */
    suspend fun duplicateSessionNow(id: String): String? = try {
        val created = repository.duplicateSession(id)
        refreshNow()
        created?.sessionId
    } catch (e: ApiError) {
        onAuthError(e)
        _uiState.update { it.copy(errorMessage = e.userMessage) }
        null
    }

    /** Forks a session from the full history; returns the fork's id. */
    suspend fun branchSessionNow(id: String): String? = try {
        val response = repository.branchSession(id)
        if (response.error != null) {
            _uiState.update { it.copy(errorMessage = response.error) }
        }
        refreshNow()
        response.sessionId
    } catch (e: ApiError) {
        onAuthError(e)
        _uiState.update { it.copy(errorMessage = e.userMessage) }
        null
    }

    fun createProject(name: String, color: String?) = projectMutate {
        val r = repository.createProject(name, color); r.error
    }

    fun renameProject(id: String, name: String, color: String?) = projectMutate {
        val r = repository.renameProject(id, name, color); r.error
    }

    fun deleteProject(id: String) = projectMutate {
        val r = repository.deleteProject(id); r.error
    }

    /** Runs a project mutation (returns a nullable error string), then refreshes. */
    private fun projectMutate(action: suspend () -> String?) {
        viewModelScope.launch {
            try {
                val error = action()
                if (error != null) _uiState.update { it.copy(errorMessage = error) }
                refreshNow()
            } catch (e: ApiError) {
                onAuthError(e)
                _uiState.update { it.copy(errorMessage = e.userMessage) }
            }
        }
    }

    private fun mutate(action: suspend () -> com.hermexapp.android.model.SessionMutationResponse) {
        viewModelScope.launch {
            try {
                val response = action()
                if (response.error != null) {
                    _uiState.update { it.copy(errorMessage = response.error) }
                }
                refreshNow()
            } catch (e: ApiError) {
                onAuthError(e)
                _uiState.update { it.copy(errorMessage = e.userMessage) }
            }
        }
    }
}
