package com.hermex.app.ui.sessionlist

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.model.ProjectSummary
import com.hermex.app.data.model.SessionMutationResponse
import com.hermex.app.data.model.SessionSummary
import com.hermex.app.data.network.ApiClient
import com.hermex.app.data.network.ApiException
import com.hermex.app.data.persistence.CachedSession
import com.hermex.app.data.persistence.SessionDao
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import javax.inject.Inject

@Immutable
data class SessionSection(
    val kind: SessionSectionKind,
    val title: String,
    val sessions: List<SessionSummary>
) {
    enum class SessionSectionKind { PINNED, TODAY, YESTERDAY, EARLIER }
}

@Immutable
data class SessionListUiState(
    val sections: List<SessionSection> = emptyList(),
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val isCreatingSession: Boolean = false,
    val isViewingCachedData: Boolean = false,
    val errorMessage: String? = null,
    val actionErrorMessage: String? = null,
    val searchQuery: String = "",
    val projects: List<ProjectSummary> = emptyList(),
    val isLoadingProjects: Boolean = false
)

@HiltViewModel
class SessionListViewModel @Inject constructor(
    private val apiClient: ApiClient,
    private val authManager: AuthManager,
    private val sessionDao: SessionDao
) : ViewModel() {

    private val _sessions = MutableStateFlow<List<SessionSummary>>(emptyList())
    private val _isLoading = MutableStateFlow(false)
    private val _isRefreshing = MutableStateFlow(false)
    private val _isCreatingSession = MutableStateFlow(false)
    private val _isViewingCachedData = MutableStateFlow(false)
    private val _errorMessage = MutableStateFlow<String?>(null)
    private val _actionErrorMessage = MutableStateFlow<String?>(null)
    private val _searchQuery = MutableStateFlow("")
    private val _projects = MutableStateFlow<List<ProjectSummary>>(emptyList())
    private val _isLoadingProjects = MutableStateFlow(false)

    private val mutatingSessionIds = MutableStateFlow<Set<String>>(emptySet())

    val uiState: StateFlow<SessionListUiState> = combine(
        _sessions,
        _isLoading,
        _isRefreshing,
        _isCreatingSession,
        _isViewingCachedData,
        _errorMessage,
        _actionErrorMessage,
        _searchQuery,
        _projects,
        _isLoadingProjects
    ) { values ->
        @Suppress("UNCHECKED_CAST")
        val sessions = values[0] as List<SessionSummary>
        val isLoading = values[1] as Boolean
        val isRefreshing = values[2] as Boolean
        val isCreatingSession = values[3] as Boolean
        val isViewingCachedData = values[4] as Boolean
        val errorMessage = values[5] as String?
        val actionErrorMessage = values[6] as String?
        val searchQuery = values[7] as String
        val projects = values[8] as List<ProjectSummary>
        val isLoadingProjects = values[9] as Boolean

        val filtered = filterSessions(sessions, searchQuery)

        SessionListUiState(
            sections = buildSections(filtered),
            isLoading = isLoading,
            isRefreshing = isRefreshing,
            isCreatingSession = isCreatingSession,
            isViewingCachedData = isViewingCachedData,
            errorMessage = errorMessage,
            actionErrorMessage = actionErrorMessage,
            searchQuery = searchQuery,
            projects = projects,
            isLoadingProjects = isLoadingProjects
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = SessionListUiState()
    )

    init {
        observeCachedSessions()
        load()
        loadProjects()

        @OptIn(FlowPreview::class)
        _searchQuery
            .debounce(300)
            .distinctUntilChanged()
            .onEach { query ->
                if (query.isBlank()) return@onEach
            }
            .launchIn(viewModelScope)
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _errorMessage.value = null
            try {
                val response = withAuthenticatedClient { apiClient.sessions() }
                val visible = response.sessions.orEmpty().filter { it.archived != true }
                _sessions.value = visible
                _isViewingCachedData.value = false
                cacheSessions(visible)
            } catch (e: Exception) {
                if (shouldUseCache(e)) {
                    _isViewingCachedData.value = true
                    _errorMessage.value = null
                } else {
                    _isViewingCachedData.value = false
                    _errorMessage.value = e.message ?: "Could not load sessions"
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isRefreshing.value = true
            _errorMessage.value = null
            try {
                val response = withAuthenticatedClient { apiClient.sessions() }
                val visible = response.sessions.orEmpty().filter { it.archived != true }
                _sessions.value = visible
                _isViewingCachedData.value = false
                cacheSessions(visible)
            } catch (e: Exception) {
                if (shouldUseCache(e)) {
                    _isViewingCachedData.value = true
                    _errorMessage.value = null
                } else {
                    _isViewingCachedData.value = false
                    _errorMessage.value = e.message ?: "Could not load sessions"
                }
            } finally {
                _isRefreshing.value = false
            }
        }
    }

    fun createSession(
        profileName: String? = null,
        onCreated: (sessionId: String) -> Unit = {}
    ) {
        viewModelScope.launch {
            _isCreatingSession.value = true
            _actionErrorMessage.value = null
            try {
                val response = withAuthenticatedClient {
                    apiClient.sessionNew(profile = profileName)
                }
                if (response.ok == true || response.session != null) {
                    val newSession = response.session
                    if (newSession?.sessionId?.isNotBlank() == true) {
                        val current = _sessions.value.toMutableList()
                        val index = current.indexOfFirst { it.sessionId == newSession.sessionId }
                        if (index >= 0) {
                            current[index] = newSession
                        } else {
                            current.add(0, newSession)
                        }
                        _sessions.value = current
                        cacheSession(newSession)
                        onCreated(newSession.sessionId)
                    } else {
                        _actionErrorMessage.value = "The server did not return the new session ID."
                    }
                } else {
                    _actionErrorMessage.value = response.error ?: "Could not create session"
                }
            } catch (e: Exception) {
                _actionErrorMessage.value = e.message ?: "Could not create session"
            } finally {
                _isCreatingSession.value = false
            }
        }
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    fun clearActionError() {
        _actionErrorMessage.value = null
    }

    fun dismissErrorMessage() {
        _errorMessage.value = null
    }

    fun togglePinned(session: SessionSummary) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            val newPinned = session.pinned != true
            apiClient.sessionPin(sessionId, pinned = newPinned)
        }
    }

    fun archive(session: SessionSummary) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            apiClient.sessionArchive(sessionId, archived = true)
            removeSessionLocally(sessionId)
        }
    }

    fun restore(session: SessionSummary) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            apiClient.sessionArchive(sessionId, archived = false)
        }
    }

    fun delete(session: SessionSummary, onDeleted: () -> Unit = {}) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            apiClient.sessionDelete(sessionId)
            removeSessionLocally(sessionId)
            sessionDao.deleteSession(sessionId)
            onDeleted()
        }
    }

    fun rename(session: SessionSummary, title: String) {
        val sessionId = session.sessionId ?: return
        if (title.isBlank()) {
            _actionErrorMessage.value = "Enter a session title."
            return
        }
        mutateSession(sessionId) {
            val response = apiClient.sessionRename(sessionId, title = title.trim())
            if (response.ok == true) {
                updateSessionLocally(sessionId) { it.copy(title = title.trim()) }
            } else {
                throw Exception(response.error ?: "Could not rename session")
            }
        }
    }

    fun duplicate(session: SessionSummary) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            val baseTitle = session.title?.trim()?.takeIf { it.isNotEmpty() } ?: "Untitled Session"
            val response = apiClient.sessionBranch(sessionId, title = "$baseTitle (copy)")
            if (response.ok == true && response.session != null) {
                refresh()
            } else {
                throw Exception(response.error ?: "Could not duplicate session")
            }
        }
    }

    fun moveToProject(session: SessionSummary, projectId: String?) {
        val sessionId = session.sessionId ?: return
        mutateSession(sessionId) {
            apiClient.sessionMove(sessionId, projectId = projectId)
            updateSessionLocally(sessionId) {
                val projectName = _projects.value.find { it.projectId == projectId }?.name
                it.copy(projectId = projectId, projectName = projectName)
            }
        }
    }

    fun loadProjects() {
        viewModelScope.launch {
            _isLoadingProjects.value = true
            try {
                val response = withAuthenticatedClient { apiClient.projects() }
                _projects.value = response.projects.orEmpty()
            } catch (e: Exception) {
                // Silently fail; projects are a secondary feature
            } finally {
                _isLoadingProjects.value = false
            }
        }
    }

    fun isMutating(session: SessionSummary): Boolean {
        return session.sessionId?.let { mutatingSessionIds.value.contains(it) } ?: false
    }

    private fun observeCachedSessions() {
        sessionDao.getAllSessions()
            .map { cached -> cached.map { it.toSummary() } }
            .onEach { cachedSessions ->
                // Only show cached sessions when we are offline and have no server data.
                if (_isViewingCachedData.value && _sessions.value.isEmpty()) {
                    _sessions.value = cachedSessions.filter { it.archived != true }
                }
            }
            .launchIn(viewModelScope)
    }

    private fun mutateSession(sessionId: String, block: suspend () -> Unit) {
        viewModelScope.launch {
            mutatingSessionIds.value += sessionId
            _actionErrorMessage.value = null
            try {
                withAuthenticatedClient { block() }
            } catch (e: Exception) {
                _actionErrorMessage.value = e.message ?: "Session action failed"
            } finally {
                mutatingSessionIds.value -= sessionId
            }
        }
    }

    private fun removeSessionLocally(sessionId: String) {
        _sessions.value = _sessions.value.filter { it.sessionId != sessionId }
    }

    private fun updateSessionLocally(sessionId: String, transform: (SessionSummary) -> SessionSummary) {
        _sessions.value = _sessions.value.map { session ->
            if (session.sessionId == sessionId) transform(session) else session
        }
    }

    private fun filterSessions(sessions: List<SessionSummary>, query: String): List<SessionSummary> {
        val normalized = query.trim().lowercase()
        val base = sessions.filter { it.archived != true }
        if (normalized.isEmpty()) return base
        return base.filter { session ->
            listOfNotNull(
                session.title,
                session.workspace,
                session.model,
                session.modelProvider,
                session.profile,
                session.projectName
            ).joinToString(" ").lowercase().contains(normalized)
        }
    }

    private fun buildSections(sessions: List<SessionSummary>): List<SessionSection> {
        val sorted = sessions.sortedWith(compareByDescending<SessionSummary> { it.pinned == true }
            .thenByDescending { it.lastMessageAt ?: it.createdAt ?: 0.0 })

        val pinned = sorted.filter { it.pinned == true }
        val unpinned = sorted.filter { it.pinned != true }

        val today = unpinned.filter { isDateGroup(it, DateGroup.TODAY) }
        val yesterday = unpinned.filter { isDateGroup(it, DateGroup.YESTERDAY) }
        val earlier = unpinned.filter { isDateGroup(it, DateGroup.EARLIER) }

        return listOfNotNull(
            pinned.takeIf { it.isNotEmpty() }?.let {
                SessionSection(SessionSection.SessionSectionKind.PINNED, "Pinned", it)
            },
            today.takeIf { it.isNotEmpty() }?.let {
                SessionSection(SessionSection.SessionSectionKind.TODAY, "Today", it)
            },
            yesterday.takeIf { it.isNotEmpty() }?.let {
                SessionSection(SessionSection.SessionSectionKind.YESTERDAY, "Yesterday", it)
            },
            earlier.takeIf { it.isNotEmpty() }?.let {
                SessionSection(SessionSection.SessionSectionKind.EARLIER, "Earlier", it)
            }
        )
    }

    private enum class DateGroup { TODAY, YESTERDAY, EARLIER }

    private fun isDateGroup(session: SessionSummary, group: DateGroup): Boolean {
        val timestamp = session.lastMessageAt ?: session.createdAt ?: return group == DateGroup.EARLIER
        if (timestamp <= 0) return group == DateGroup.EARLIER
        val instant = Instant.ofEpochSecond(timestamp.toLong())
        val zone = ZoneId.systemDefault()
        val date = instant.atZone(zone).toLocalDate()
        val today = LocalDate.now(zone)
        return when (group) {
            DateGroup.TODAY -> date.isEqual(today)
            DateGroup.YESTERDAY -> date.isEqual(today.minusDays(1))
            DateGroup.EARLIER -> date.isBefore(today.minusDays(1))
        }
    }

    private suspend fun <T> withAuthenticatedClient(block: suspend () -> T): T {
        configureFromSavedServer()
        return try {
            block()
        } catch (unauthorized: ApiException.Unauthorized) {
            reauthenticate()
            block()
        }
    }

    private fun configureFromSavedServer() {
        val serverUrl = authManager.serverUrl?.takeIf { it.isNotBlank() }
            ?: throw IllegalStateException("Server is not configured. Tap Reconnect to sign in again.")
        apiClient.configure(serverUrl)
    }

    private suspend fun reauthenticate() {
        val password = authManager.getPassword()?.takeIf { it.isNotBlank() }
            ?: run {
                authManager.markLoggedOut()
                throw ApiException.Unauthorized(401, "Session expired. Tap Reconnect to sign in again.")
            }
        val response = apiClient.login(password)
        if (response.ok == true) {
            authManager.markLoggedIn()
        } else {
            authManager.markLoggedOut()
            throw ApiException.Unauthorized(401, response.error ?: "Login failed. Tap Reconnect to sign in again.")
        }
    }

    private fun shouldUseCache(error: Throwable): Boolean {
        return error is IOException ||
            (error.message?.contains("Unable to resolve host", ignoreCase = true) == true) ||
            (error.message?.contains("Connect", ignoreCase = true) == true) ||
            (error.message?.contains("Socket", ignoreCase = true) == true) ||
            (error.message?.contains("timeout", ignoreCase = true) == true)
    }

    private suspend fun cacheSessions(sessions: List<SessionSummary>) {
        sessionDao.insertSessions(sessions.map { it.toCachedSession() })
    }

    private suspend fun cacheSession(session: SessionSummary) {
        sessionDao.insertSession(session.toCachedSession())
    }

    private fun SessionSummary.toCachedSession(): CachedSession = CachedSession(
        sessionId = sessionId ?: "",
        title = title,
        lastMessageAt = lastMessageAt,
        createdAt = createdAt,
        updatedAt = updatedAt,
        pinned = pinned,
        archived = archived,
        model = model,
        modelProvider = modelProvider,
        profile = profile,
        workspace = workspace,
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        estimatedCost = estimatedCost,
        projectId = projectId,
        projectName = projectName,
        messageCount = messageCount
    )

    private fun CachedSession.toSummary(): SessionSummary = SessionSummary(
        sessionId = sessionId,
        title = title,
        lastMessageAt = lastMessageAt,
        createdAt = createdAt,
        updatedAt = updatedAt,
        pinned = pinned,
        archived = archived,
        model = model,
        modelProvider = modelProvider,
        profile = profile,
        workspace = workspace,
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        estimatedCost = estimatedCost,
        projectId = projectId,
        projectName = projectName,
        messageCount = messageCount
    )
}
