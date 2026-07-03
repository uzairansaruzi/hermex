package com.hermex.app.data.network

import com.hermex.app.data.auth.AuthManager
import kotlinx.serialization.json.Json
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.Route
import javax.inject.Inject
import javax.inject.Singleton

/**
 * OkHttp Authenticator that transparently retries 401 responses by
 * re-logging-in with the saved password.  This covers every API call
 * and SSE connection made through the shared OkHttpClient, so
 * individual ViewModels no longer need their own reauth logic.
 */
@Singleton
class HermesAuthenticator @Inject constructor(
    private val authManager: AuthManager,
    private val cookieJar: CookieJar,
    private val json: Json
) : Authenticator {

    private val lock = Any()

    override fun authenticate(route: Route?, response: Response): Request? {
        val originalRequest = response.request

        // Don't retry the login endpoint itself — infinite loop.
        if (originalRequest.url.encodedPath.endsWith(Endpoints.LOGIN)) return null

        // OkHttp already retried once if priorResponse is set — give up.
        if (response.priorResponse != null) return null

        val password = authManager.getPassword()?.takeIf { it.isNotBlank() }
        if (password == null) {
            authManager.markLoggedOut()
            return null
        }

        synchronized(lock) {
            // Another thread may have already refreshed the session.  Re-check
            // by looking at the cookie jar: if a fresh cookie was stored for
            // our host since the failing request, just retry with it.
            val existingCookies = cookieJar.loadForRequest(originalRequest.url)
            if (existingCookies.isNotEmpty() && response.priorResponse == null) {
                // Cookies exist — they *might* be the same stale ones, but
                // the simplest safe path is to let OkHttp re-send the request
                // with whatever's in the jar.  If they're still bad, the
                // priorResponse guard above stops the next retry.
            }

            // Build a login request against the same scheme://host:port as the
            // failing request, so we don't depend on ApiClient.baseUrl (which
            // could theoretically be reconfigured mid-flight).
            val loginUrl = originalRequest.url.newBuilder()
                .encodedPath(Endpoints.LOGIN)
                .query(null)
                .build()

            val loginBody = json.encodeToString(
                kotlinx.serialization.serializer<Map<String, String>>(),
                mapOf("password" to password)
            ).toRequestBody("application/json".toMediaType())

            // Use a minimal client with the *shared* CookieJar and cleartext
            // interceptor.  We cannot use the main OkHttpClient (it would
            // invoke this Authenticator recursively on a login 401).
            val loginClient = OkHttpClient.Builder()
                .addInterceptor(LocalCleartextInterceptor())
                .cookieJar(cookieJar)
                .build()

            val loginRequest = Request.Builder()
                .url(loginUrl)
                .post(loginBody)
                .build()

            return try {
                val loginResponse = loginClient.newCall(loginRequest).execute()
                val body = loginResponse.body?.string().orEmpty()
                if (loginResponse.isSuccessful) {
                    val parsed = json.decodeFromString<com.hermex.app.data.model.LoginResponse>(body)
                    if (parsed.ok == true) {
                        authManager.markLoggedIn()
                        // Retry the original request — the cookie jar now has
                        // the fresh session cookie from the login response.
                        return originalRequest
                    }
                }
                authManager.markLoggedOut()
                null
            } catch (_: Exception) {
                authManager.markLoggedOut()
                null
            }
        }
    }
}
