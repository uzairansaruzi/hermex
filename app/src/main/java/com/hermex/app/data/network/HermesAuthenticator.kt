package com.hermex.app.data.network

import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.model.LoginResponse
import kotlinx.serialization.json.Json
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.Route
import java.io.IOException
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

        // Capture the Cookie header the failing request was actually sent with.
        // BridgeInterceptor set this from the jar when the request went out.
        val sentCookieHeader = response.networkResponse?.request?.header("Cookie")

        synchronized(lock) {
            // Another thread may have already refreshed the session while we
            // waited on the lock.  Compare the cookies the jar would send NOW
            // against what the failing request originally sent.
            val currentCookieHeader = cookieJar.loadForRequest(originalRequest.url)
                .joinToString("; ") { "${it.name}=${it.value}" }
                .ifEmpty { null }

            if (currentCookieHeader != null && currentCookieHeader != sentCookieHeader) {
                // Fresh cookies from another thread's login — retry the original
                // request without logging in again.  BridgeInterceptor re-reads
                // the jar on retry, so we don't set the Cookie header manually.
                // If the fresh cookies are still bad, the priorResponse guard
                // above stops the next attempt.
                return originalRequest
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
                loginClient.newCall(loginRequest).execute().use { loginResponse ->
                    val body = loginResponse.body?.string().orEmpty()
                    when {
                        loginResponse.isSuccessful -> {
                            val parsed = runCatching {
                                json.decodeFromString<LoginResponse>(body)
                            }.getOrNull()
                            when (parsed?.ok) {
                                true -> {
                                    authManager.markLoggedIn()
                                    // Retry the original request — the cookie jar
                                    // now has the fresh session cookie.
                                    originalRequest
                                }
                                false -> {
                                    // Definitive rejection (bad password).
                                    authManager.markLoggedOut()
                                    null
                                }
                                null -> {
                                    // Undecodable 2xx: treat as transient — don't
                                    // change auth state.
                                    null
                                }
                            }
                        }
                        loginResponse.code == 401 || loginResponse.code == 403 -> {
                            // Definitive auth rejection.
                            authManager.markLoggedOut()
                            null
                        }
                        else -> {
                            // Server error (5xx) or other transient failure —
                            // do NOT change auth state.
                            null
                        }
                    }
                }
            } catch (_: IOException) {
                // Network-level failure (timeout, DNS, tunnel blip) — never
                // change auth state; the user stays logged in and can retry.
                null
            }
        }
    }
}
