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
 * The Android counterpart of the iOS `APIClient` actor: one instance per server
 * base URL, JSON in/out, tolerant decoding, and the same error mapping
 * (401 → [ApiError.Unauthorized], other non-2xx → [ApiError.Http], transport →
 * [ApiError.Network], parse → [ApiError.Decoding]).
 *
 * The session cookie rides in the injected [OkHttpClient]'s cookie jar
 * ([SessionCookieJar]), exactly as the iOS client leans on `HTTPCookieStorage`.
 */
class ApiClient(
    val baseUrl: HttpUrl,
    private val httpClient: OkHttpClient,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    init {
        // Defense in depth behind ServerUrlNormalizer: no client may exist for a
        // cleartext URL outside the allowed set (Android port plan §2).
        if (baseUrl.scheme == "http" && !CleartextPolicy.allowsCleartext(baseUrl.host)) {
            throw ApiError.CleartextNotAllowed(baseUrl.host)
        }
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    suspend fun health(): HealthResponse = get(Endpoint.HEALTH)

    suspend fun authStatus(): AuthStatusResponse = get(Endpoint.AUTH_STATUS)

    suspend fun login(password: String): LoginResponse =
        post(Endpoint.LOGIN, json.encodeToString(LoginRequest(password)))

    suspend fun logout(): LoginResponse = post(Endpoint.LOGOUT, "{}")

    private suspend inline fun <reified T> get(endpoint: Endpoint): T =
        decode(execute(requestBuilder(endpoint).get().build()))

    private suspend inline fun <reified T> post(endpoint: Endpoint, body: String): T =
        decode(execute(requestBuilder(endpoint).post(body.toRequestBody(jsonMediaType)).build()))

    private fun requestBuilder(endpoint: Endpoint): Request.Builder {
        val url = baseUrl.newBuilder()
            .encodedPath(endpoint.path)
            .build()
        return Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            // Mirror the iOS `reloadIgnoringLocalCacheData`: control-plane calls
            // must always hit the server.
            .header("Cache-Control", "no-cache")
    }

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

    private inline fun <reified T> decode(body: String): T = try {
        json.decodeFromString<T>(body)
    } catch (e: SerializationException) {
        throw ApiError.Decoding(e)
    } catch (e: IllegalArgumentException) {
        throw ApiError.Decoding(e)
    }

    @Serializable
    private data class LoginRequest(val password: String)
}
