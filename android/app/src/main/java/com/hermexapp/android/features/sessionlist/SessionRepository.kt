package com.hermexapp.android.features.sessionlist

import com.hermexapp.android.model.SessionDetail
import com.hermexapp.android.model.SessionSummary
import com.hermexapp.android.model.SessionsResponse
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.ApiJson
import com.hermexapp.android.network.archiveSession
import com.hermexapp.android.network.branchSession
import com.hermexapp.android.network.createSession
import com.hermexapp.android.network.deleteSession
import com.hermexapp.android.network.duplicateSession
import com.hermexapp.android.network.moveSession
import com.hermexapp.android.network.createProject
import com.hermexapp.android.network.deleteProject
import com.hermexapp.android.network.pinSession
import com.hermexapp.android.network.projects
import com.hermexapp.android.network.renameProject
import com.hermexapp.android.network.renameSession
import com.hermexapp.android.network.searchSessions
import com.hermexapp.android.network.session
import com.hermexapp.android.network.sessions
import com.hermexapp.android.persistence.CacheStore
import kotlinx.serialization.encodeToString

/**
 * Sessions with an offline read path (plan phase 3): network responses are
 * cached as raw JSON per server host; when the network fails, the last cached
 * copy is served with an `offline` marker so the UI can say so. Mirrors the
 * intent of the iOS `CacheFallbackPolicy` + SwiftData cache in one seam.
 */
class SessionRepository(
    private val client: ApiClient,
    private val cache: CacheStore,
) {
    private val host: String get() = client.baseUrl.host

    data class SessionsResult(val sessions: List<SessionSummary>, val fromCache: Boolean)

    /** Network first; on failure fall back to cache; rethrow when neither works. */
    suspend fun loadSessions(): SessionsResult {
        val response = try {
            client.sessions()
        } catch (e: ApiError) {
            // Session expiry must surface (it changes auth state), never be
            // masked by a stale cache.
            if (e is ApiError.Unauthorized) throw e
            val cached = cache.load(CacheStore.sessionsKey(host)) ?: throw e
            val decoded = try {
                ApiJson.decodeFromString<SessionsResponse>(cached)
            } catch (_: Exception) {
                throw e
            }
            return SessionsResult(sort(decoded.sessions.orEmpty()), fromCache = true)
        }

        cache.save(CacheStore.sessionsKey(host), ApiJson.encodeToString(response))
        return SessionsResult(sort(response.sessions.orEmpty()), fromCache = false)
    }

    /** Server-side search (`/api/sessions/search`) — network only, like iOS. */
    suspend fun search(query: String): List<SessionSummary> =
        sort(client.searchSessions(query).sessions.orEmpty())

    /** Session detail incl. transcript; cached for offline reopening. */
    suspend fun loadSession(id: String): Pair<SessionDetail?, Boolean> {
        val key = CacheStore.sessionKey(host, id)
        val response = try {
            client.session(id)
        } catch (e: ApiError) {
            if (e is ApiError.Unauthorized) throw e
            val cached = cache.load(key) ?: throw e
            val decoded = try {
                ApiJson.decodeFromString<com.hermexapp.android.model.SessionResponse>(cached)
            } catch (_: Exception) {
                throw e
            }
            return decoded.session to true
        }

        cache.save(key, ApiJson.encodeToString(response))
        return response.session to false
    }

    suspend fun createSession(): SessionDetail? = client.createSession().session

    suspend fun renameSession(id: String, title: String) = client.renameSession(id, title)

    suspend fun deleteSession(id: String) = client.deleteSession(id)

    suspend fun pinSession(id: String, pinned: Boolean) = client.pinSession(id, pinned)

    suspend fun archiveSession(id: String, archived: Boolean) = client.archiveSession(id, archived)

    suspend fun duplicateSession(id: String): SessionDetail? = client.duplicateSession(id).session

    suspend fun moveSession(id: String, projectId: String?) = client.moveSession(id, projectId)

    suspend fun branchSession(id: String, keepCount: Int? = null, title: String? = null) =
        client.branchSession(id, keepCount, title)

    /** Projects (folders) for the active profile. Network only, like the list. */
    suspend fun loadProjects(): List<com.hermexapp.android.model.Project> =
        client.projects().projects.orEmpty()

    suspend fun createProject(name: String, color: String?) = client.createProject(name, color)

    suspend fun renameProject(id: String, name: String, color: String?) =
        client.renameProject(id, name, color)

    suspend fun deleteProject(id: String) = client.deleteProject(id)

    /** Pinned first, then most recent activity — matches the sidebar ordering. */
    private fun sort(sessions: List<SessionSummary>): List<SessionSummary> =
        sessions.sortedWith(
            compareByDescending<SessionSummary> { it.pinned == true }
                .thenByDescending { it.lastMessageAt ?: it.updatedAt ?: it.createdAt ?: 0.0 },
        )
}
