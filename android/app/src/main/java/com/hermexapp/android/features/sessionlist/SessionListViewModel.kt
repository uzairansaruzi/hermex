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
}
