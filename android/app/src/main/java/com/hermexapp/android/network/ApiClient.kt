package com.hermexapp.android.network

import com.hermexapp.android.model.AuthStatusResponse
import com.hermexapp.android.model.HealthResponse
import com.hermexapp.android.model.LoginResponse
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * The app's one tolerant Json configuration (hard rule #3): unknown keys are
 * ignored, lenient primitives are accepted (numbers-as-strings and vice
 * versa), explicit nulls fall back to field defaults, and nulls are omitted
 * when encoding (matching how the iOS encoder omits nil optionals).
 */
val ApiJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    explicitNulls = false
}

/**
 * The Android counterpart of the iOS `APIClient` actor: one instance per server
 * base URL, JSON in/out, tolerant decoding, and the same error mapping
 * (401 → [ApiError.Unauthorized], other non-2xx → [ApiError.Http], transport →
 * [ApiError.Network], parse → [ApiError.Decoding]).
 *
 * Endpoint families live in extension files mirroring the iOS split
 * (`ApiClientSessions.kt`, `ApiClientChat.kt`), built on [getJson]/[postJson].
 * The session cookie rides in the injected [OkHttpClient]'s cookie jar.
 */
class ApiClient(
    val baseUrl: HttpUrl,
    @PublishedApi internal val httpClient: OkHttpClient,
    @PublishedApi internal val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    init {
        // Defense in depth behind ServerUrlNormalizer: no client may exist for a
        // cleartext URL outside the allowed set (Android port plan §2).
        if (baseUrl.scheme == "http" && !CleartextPolicy.allowsCleartext(baseUrl.host)) {
            throw ApiError.CleartextNotAllowed(baseUrl.host)
        }
    }

    @PublishedApi internal val json: Json = ApiJson
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    suspend fun health(): HealthResponse = getJson(Endpoint.HEALTH)

    suspend fun authStatus(): AuthStatusResponse = getJson(Endpoint.AUTH_STATUS)

    suspend fun login(password: String): LoginResponse =
        postJson(Endpoint.LOGIN, json.encodeToString(LoginRequest(password)))

    suspend fun logout(): LoginResponse = postJson(Endpoint.LOGOUT, "{}")

    /** Builds an endpoint URL with query parameters, e.g. for the SSE stream. */
    fun url(endpoint: Endpoint, query: Map<String, String> = emptyMap()): HttpUrl {
        val builder = baseUrl.newBuilder().encodedPath(endpoint.path)
        for ((name, value) in query) builder.addQueryParameter(name, value)
        return builder.build()
    }

    suspend inline fun <reified T> getJson(
        endpoint: Endpoint,
        query: Map<String, String> = emptyMap(),
    ): T = decode(executeGet(endpoint, query))

    suspend inline fun <reified T> postJson(endpoint: Endpoint, body: String): T =
        decode(executePost(endpoint, body))

    @PublishedApi
    internal suspend fun executeGet(endpoint: Endpoint, query: Map<String, String>): String =
        execute(requestBuilder(endpoint, query).get().build())

    @PublishedApi
    internal suspend fun executePost(endpoint: Endpoint, body: String): String =
        execute(requestBuilder(endpoint, emptyMap()).post(body.toRequestBody(jsonMediaType)).build())

    private fun requestBuilder(endpoint: Endpoint, query: Map<String, String>): Request.Builder =
        Request.Builder()
            .url(url(endpoint, query))
            .header("Accept", "application/json")
            // Mirror the iOS `reloadIgnoringLocalCacheData`: control-plane calls
            // must always hit the server.
            .header("Cache-Control", "no-cache")

    private suspend fun execute(request: Request): String = withContext(ioDispatcher) {
        val response = try {
            httpClient.newCall(request).execute()
        } catch (e: IOException) {
            throw ApiError.Network(e)
        }

        response.use {
            val bodyText = try {
                it.body?.string().orEmpty()
            } catch (e: IOException) {
                throw ApiError.Network(e)
            }

            when {
                it.code == 401 -> throw ApiError.Unauthorized
                it.code !in 200..299 -> throw ApiError.Http(it.code, bodyText.ifEmpty { null })
                else -> bodyText
            }
        }
    }

    @PublishedApi
    internal inline fun <reified T> decode(body: String): T = try {
        json.decodeFromString<T>(body)
    } catch (e: SerializationException) {
        throw ApiError.Decoding(e)
    } catch (e: IllegalArgumentException) {
        throw ApiError.Decoding(e)
    }

    @Serializable
    private data class LoginRequest(val password: String)
}
