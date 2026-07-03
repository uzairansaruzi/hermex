package com.hermex.app.data.network

import com.hermex.app.data.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ApiClient @Inject constructor(
    private val okHttpClient: OkHttpClient,
    private val json: Json
) {
    var baseUrl: String = ""
        private set

    fun configure(serverUrl: String) {
        baseUrl = normalizeServerUrl(serverUrl)
    }

    suspend fun health(): HealthResponse = get(Endpoints.HEALTH)

    suspend fun authStatus(): AuthStatusResponse = get(Endpoints.AUTH_STATUS)

    suspend fun login(password: String): LoginResponse {
        return post(Endpoints.LOGIN, LoginRequest(password = password))
    }

    suspend fun logout(): LoginResponse = post(Endpoints.LOGOUT, emptyMap<String, String>())

    suspend fun sessions(): SessionsResponse = get(Endpoints.SESSIONS)

    suspend fun session(sessionId: String, messages: Boolean = true, msgLimit: Int = 50): SessionResponse {
        val params = buildMap {
            put("session_id", sessionId)
            if (messages) put("messages", "1")
            put("msg_limit", msgLimit.toString())
        }
        return get(Endpoints.SESSION, params)
    }

    suspend fun sessionNew(workspace: String? = null, model: String? = null, profile: String? = null): SessionMutationResponse {
        return post(Endpoints.SESSION_NEW, buildMap {
            workspace?.let { put("workspace", it) }
            model?.let { put("model", it) }
            profile?.let { put("profile", it) }
        })
    }

    suspend fun sessionRename(sessionId: String, title: String): SessionMutationResponse {
        return post(Endpoints.SESSION_RENAME, mapOf("session_id" to sessionId, "title" to title))
    }

    suspend fun sessionDelete(sessionId: String): SessionMutationResponse {
        return post(Endpoints.SESSION_DELETE, mapOf("session_id" to sessionId))
    }

    suspend fun sessionPin(sessionId: String, pinned: Boolean): SessionMutationResponse {
        return post(Endpoints.SESSION_PIN, mapOf("session_id" to sessionId, "pinned" to pinned))
    }

    suspend fun sessionArchive(sessionId: String, archived: Boolean): SessionMutationResponse {
        return post(Endpoints.SESSION_ARCHIVE, mapOf("session_id" to sessionId, "archived" to archived))
    }

    suspend fun sessionMove(sessionId: String, projectId: String?): SessionMutationResponse {
        return post(Endpoints.SESSION_MOVE, buildMap {
            put("session_id", sessionId)
            projectId?.let { put("project_id", it) }
        })
    }

    suspend fun sessionBranch(sessionId: String, keepCount: Int? = null, title: String? = null): SessionMutationResponse {
        return post(Endpoints.SESSION_BRANCH, buildMap {
            put("session_id", sessionId)
            keepCount?.let { put("keep_count", it) }
            title?.let { put("title", it) }
        })
    }

    suspend fun sessionTruncate(sessionId: String, keepCount: Int): SessionMutationResponse {
        return post(Endpoints.SESSION_TRUNCATE, mapOf("session_id" to sessionId, "keep_count" to keepCount))
    }

    suspend fun projects(): ProjectsResponse = get(Endpoints.PROJECTS)

    suspend fun chatStart(request: ChatStartRequest): ChatStartResponse = post(Endpoints.CHAT_START, request)

    suspend fun chatCancel(streamId: String) {
        get<Unit>("${Endpoints.CHAT_CANCEL}?stream_id=$streamId")
    }

    suspend fun chatStreamStatus(streamId: String): StreamStatusResponse {
        return get(Endpoints.CHAT_STREAM_STATUS, mapOf("stream_id" to streamId))
    }

    suspend fun chatSteer(request: ChatSteerRequest): ChatSteerResponse = post(Endpoints.CHAT_STEER, request)

    suspend fun workspaces(): WorkspacesResponse = get(Endpoints.WORKSPACES)

    suspend fun listFiles(sessionId: String, path: String): List<WorkspaceEntry> {
        return get<FileListResponse>(Endpoints.LIST_FILES, mapOf("session_id" to sessionId, "path" to path))
            .entries.orEmpty()
    }

    suspend fun fileContent(sessionId: String, path: String): FileContentResponse {
        return get(Endpoints.FILE, mapOf("session_id" to sessionId, "path" to path))
    }

    suspend fun models(): ModelsResponse = get(Endpoints.MODELS)

    suspend fun providers(): ProvidersResponse = get(Endpoints.PROVIDERS)

    suspend fun settings(): SettingsResponse = get(Endpoints.SETTINGS)

    suspend fun defaultModel(model: String) {
        post<Unit>(Endpoints.DEFAULT_MODEL, mapOf("model" to model))
    }

    suspend fun reasoning(): ReasoningResponse = get(Endpoints.REASONING)

    suspend fun reasoningSet(effort: String) {
        post<Unit>(Endpoints.REASONING, ReasoningRequest(effort = effort))
    }

    suspend fun profiles(): ProfilesResponse = get(Endpoints.PROFILES)

    suspend fun profileSwitch(profile: String) {
        post<Unit>(Endpoints.PROFILE_SWITCH, mapOf("profile" to profile))
    }

    suspend fun personalities(): PersonalitiesResponse = get(Endpoints.PERSONALITIES)

    suspend fun commands(): CommandsResponse = get(Endpoints.COMMANDS)

    suspend fun crons(): CronsResponse = get(Endpoints.CRONS)

    suspend fun cronStatus(jobId: String? = null): CronStatusResponse {
        return if (jobId != null) get(Endpoints.CRONS_STATUS, mapOf("job_id" to jobId))
        else get(Endpoints.CRONS_STATUS)
    }

    suspend fun cronOutput(jobId: String, limit: Int = 20): CronOutputResponse {
        return get(Endpoints.CRONS_OUTPUT, mapOf("job_id" to jobId, "limit" to limit.toString()))
    }

    suspend fun skills(): SkillsResponse = get(Endpoints.SKILLS)

    suspend fun skillContent(name: String, file: String? = null): SkillContentResponse {
        val params = buildMap {
            put("name", name)
            file?.let { put("file", it) }
        }
        return get(Endpoints.SKILLS_CONTENT, params)
    }

    suspend fun memory(): MemoryResponse = get(Endpoints.MEMORY)

    suspend fun gitStatus(sessionId: String): GitStatusResponse {
        return get<GitStatusEnvelope>(Endpoints.GIT_STATUS, mapOf("session_id" to sessionId)).git ?: GitStatusResponse()
    }

    suspend fun gitBranches(sessionId: String): GitBranchesResponse {
        return get(Endpoints.GIT_BRANCHES, mapOf("session_id" to sessionId))
    }

    suspend fun gitDiff(sessionId: String): GitDiffResponse {
        return get(Endpoints.GIT_DIFF, mapOf("session_id" to sessionId))
    }

    fun streamUrl(streamId: String): HttpUrl {
        return "${baseUrl}${Endpoints.CHAT_STREAM}?stream_id=$streamId".toHttpUrl()
    }

    fun rawUrl(path: String): String {
        return "$baseUrl$path"
    }

    // Generic GET/POST helpers
    private suspend inline fun <reified T> get(path: String, params: Map<String, String> = emptyMap()): T {
        val url = buildUrl(path, params)
        val request = Request.Builder().url(url).get().build()
        return executeRequest(request)
    }

    private suspend inline fun <reified T> post(path: String, body: Any): T {
        val url = buildUrl(path)
        val jsonBody = encodePostBody(body)
        val request = Request.Builder()
            .url(url)
            .post(jsonBody.toRequestBody("application/json".toMediaType()))
            .build()
        return executeRequest(request)
    }

    private fun buildUrl(path: String, params: Map<String, String> = emptyMap()): HttpUrl {
        val urlBuilder = "$baseUrl$path".toHttpUrl().newBuilder()
        params.forEach { (key, value) -> urlBuilder.addQueryParameter(key, value) }
        return urlBuilder.build()
    }

    private fun encodePostBody(body: Any): String = when (body) {
        is String -> body
        is Map<*, *> -> mapToJsonObject(body).toString()
        is LoginRequest -> json.encodeToString(body)
        is ChatStartRequest -> json.encodeToString(body)
        is ChatSteerRequest -> json.encodeToString(body)
        is ReasoningRequest -> json.encodeToString(body)
        else -> error("Unsupported request body type: ${body::class.qualifiedName}")
    }

    private fun mapToJsonObject(map: Map<*, *>): JsonObject = buildJsonObject {
        map.forEach { (key, value) ->
            if (key != null) put(key.toString(), anyToJsonElement(value))
        }
    }

    private fun anyToJsonElement(value: Any?): JsonElement {
        return when (value) {
            null -> JsonNull
            is JsonElement -> value
            is String -> JsonPrimitive(value)
            is Boolean -> JsonPrimitive(value)
            is Number -> JsonPrimitive(value)
            is Map<*, *> -> mapToJsonObject(value)
            is Iterable<*> -> buildJsonArray { value.forEach { add(anyToJsonElement(it)) } }
            is Array<*> -> buildJsonArray { value.forEach { add(anyToJsonElement(it)) } }
            else -> JsonPrimitive(value.toString())
        }
    }

    private suspend inline fun <reified T> executeRequest(request: Request): T {
        return withContext(Dispatchers.IO) {
            val response = okHttpClient.newCall(request).execute()
            val body = response.body?.string() ?: ""

            if (!response.isSuccessful) {
                when (response.code) {
                    401 -> throw ApiException.Unauthorized(response.code, body)
                    else -> throw ApiException.Http(response.code, body)
                }
            }

            if (body.isBlank() || T::class == Unit::class) {
                @Suppress("UNCHECKED_CAST")
                return@withContext Unit as T
            }

            try {
                json.decodeFromString<T>(body)
            } catch (e: Exception) {
                throw ApiException.Decoding(e)
            }
        }
    }
}

sealed class ApiException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    data class Http(val code: Int, val body: String) : ApiException("HTTP $code: $body")
    data class Unauthorized(val code: Int, val body: String) : ApiException("Unauthorized: $body")
    data class Decoding(val underlying: Throwable) : ApiException("Decoding error: ${underlying.message}", underlying)
    data class Network(val underlying: IOException) : ApiException("Network error: ${underlying.message}", underlying)
}
