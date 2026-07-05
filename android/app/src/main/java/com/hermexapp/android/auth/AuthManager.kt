package com.hermexapp.android.auth

import com.hermexapp.android.model.AuthStatusResponse
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.SessionCookieJar
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl

/**
 * What the onboarding flow needs from auth — lets the view model be tested
 * against a fake (the Android counterpart of the iOS `AuthAPIClient` seam).
 */
interface AuthGateway {
    val lastErrorMessage: StateFlow<String?>
    suspend fun testConnection(serverUrlString: String): AuthStatusResponse
    suspend fun configure(serverUrlString: String, password: String)
}

/**
 * Single-server port of the iOS `AuthManager` (the multi-server registry and
 * custom headers are later iOS features, out of phase 1 scope): owns the
 * configured server URL (persisted in the [SecretStore], never the password),
 * the login flow against the upstream auth contract, and the auth state the UI
 * switches on. The session rides in the `hermes_session` cookie held by
 * [SessionCookieJar]; a 401 anywhere demotes state to [State.LoggedOut].
 */
class AuthManager(
    private val secretStore: SecretStore,
    private val cookieJar: SessionCookieJar,
    private val clientFactory: (HttpUrl) -> ApiClient,
    private val logoutTimeoutMillis: Long = 5_000,
    // Multi-server registry (nullable so tests can omit it). Kept in sync so the
    // settings server switcher and the header interceptor see every server.
    private val registry: com.hermexapp.android.config.ServerRegistry? = null,
) : AuthGateway {

    sealed class State {
        /** The server this state refers to — `Unconfigured` has none. */
        abstract val server: HttpUrl?

        data object Unconfigured : State() {
            override val server: HttpUrl? get() = null
        }

        data class LoggedOut(override val server: HttpUrl) : State()
        data class LoggedIn(override val server: HttpUrl) : State()
    }

    private val _state = MutableStateFlow<State>(State.Unconfigured)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _lastErrorMessage = MutableStateFlow<String?>(null)
    override val lastErrorMessage: StateFlow<String?> = _lastErrorMessage.asStateFlow()

    init {
        restoreSavedServer()
    }

    /**
     * Probes a server: `/health` must report `status == "ok"`, then
     * `/api/auth/status` says whether a password is needed. Mirrors the iOS
     * `testConnection`. Throws [ApiError] on any failure.
     */
    override suspend fun testConnection(serverUrlString: String): AuthStatusResponse {
        val serverUrl = ServerUrlNormalizer.normalize(serverUrlString)
        return testConnection(clientFactory(serverUrl))
    }

    private suspend fun testConnection(client: ApiClient): AuthStatusResponse {
        val health = client.health()
        if (health.status != "ok") {
            throw ApiError.Http(statusCode = 200, body = "Unexpected health status.")
        }
        return client.authStatus()
    }

    /**
     * Full connect: probe, then log in when the server requires it, then persist
     * the server URL — only on success, mirroring the iOS `configure`. Failures
     * land in [lastErrorMessage] rather than throwing, so the UI shows them.
     */
    override suspend fun configure(serverUrlString: String, password: String) {
        _lastErrorMessage.value = null

        try {
            val serverUrl = ServerUrlNormalizer.normalize(serverUrlString)
            val client = clientFactory(serverUrl)
            val authStatus = testConnection(client)

            // Passkey-only: auth on but password auth explicitly off. Only an
            // explicit false counts — a missing field is an older server, which
            // must fall through to the password path.
            if (authStatus.authEnabled == true && authStatus.passwordAuthEnabled == false) {
                _lastErrorMessage.value = PASSKEY_ONLY_MESSAGE
                return
            }

            if (authStatus.authEnabled == true) {
                if (password.isEmpty()) {
                    _lastErrorMessage.value = EMPTY_PASSWORD_MESSAGE
                    return
                }
                val loginResponse = client.login(password)
                if (loginResponse.ok != true) {
                    _state.value = State.LoggedOut(serverUrl)
                    _lastErrorMessage.value = ApiError.Unauthorized.userMessage
                    return
                }
            }

            secretStore.save(serverUrl.toString(), SecretStore.Key.SERVER_URL)
            registry?.addOrKeep(serverUrl.toString())
            _state.value = State.LoggedIn(serverUrl)
        } catch (e: ApiError) {
            _lastErrorMessage.value = e.userMessage
        }
    }

    /**
     * Switches the active server to an already-known one (settings server
     * switcher). Its cookies load per-host automatically; a stale one is demoted
     * to LoggedOut by the first 401 via [handleApiError], exactly like cold
     * launch.
     */
    fun switchTo(serverUrlString: String) {
        val url = runCatching { ServerUrlNormalizer.normalize(serverUrlString) }.getOrNull() ?: return
        secretStore.save(url.toString(), SecretStore.Key.SERVER_URL)
        _lastErrorMessage.value = null
        _state.value = State.LoggedIn(url)
    }

    /**
     * Drops to onboarding to add another server WITHOUT signing out of the
     * current one — the registry and cookies are left intact so the user can
     * switch back. Connecting a new server just makes it the active one.
     */
    fun beginAddServer() {
        _lastErrorMessage.value = null
        _state.value = State.Unconfigured
    }

    /** Forgets a server: server-side logout, drop its cookies + registry entry. */
    suspend fun forgetServer(serverUrlString: String) {
        val url = runCatching { ServerUrlNormalizer.normalize(serverUrlString) }.getOrNull() ?: return
        val isActive = _state.value.server?.host == url.host
        if (isActive && _state.value is State.LoggedIn) {
            withTimeoutOrNull(logoutTimeoutMillis) { runCatching { clientFactory(url).logout() } }
        }
        cookieJar.clear(url.host)
        registry?.remove(url.toString())
        if (isActive) {
            secretStore.delete(SecretStore.Key.SERVER_URL)
            val next = registry?.servers?.value?.firstOrNull()
            if (next != null) switchTo(next.url) else _state.value = State.Unconfigured
        }
    }

    /**
     * Best-effort server-side logout (bounded, never blocks local sign-out —
     * mirrors iOS `attemptBestEffortServerLogout`), then clears the saved server
     * and its cookies and returns to onboarding.
     */
    suspend fun signOut() {
        val server = _state.value.server
        if (server != null && _state.value is State.LoggedIn) {
            withTimeoutOrNull(logoutTimeoutMillis) {
                runCatching { clientFactory(server).logout() }
            }
        }
        server?.let { cookieJar.clear(it.host) }
        secretStore.delete(SecretStore.Key.SERVER_URL)
        _lastErrorMessage.value = null
        _state.value = State.Unconfigured
    }

    /**
     * Routes any API failure through session-expiry handling: a 401 keeps the
     * saved server (re-login is a one-field affair) but clears its cookies and
     * demotes state to LoggedOut. Everything else is left to the caller.
     */
    fun handleApiError(error: Throwable) {
        if (error !is ApiError.Unauthorized) return

        _lastErrorMessage.value = "Your session expired. Sign in again."
        when (val current = _state.value) {
            is State.LoggedIn -> {
                cookieJar.clear(current.server.host)
                _state.value = State.LoggedOut(current.server)
            }
            is State.LoggedOut -> cookieJar.clear(current.server.host)
            State.Unconfigured -> Unit
        }
    }

    private fun restoreSavedServer() {
        val saved = secretStore.load(SecretStore.Key.SERVER_URL) ?: return
        val url = try {
            ServerUrlNormalizer.normalize(saved)
        } catch (_: ApiError) {
            secretStore.delete(SecretStore.Key.SERVER_URL)
            return
        }
        // Optimistic, like the iOS cold-launch path: a stale cookie is demoted to
        // LoggedOut by the first request's 401 via handleApiError.
        _state.value = State.LoggedIn(url)
    }

    companion object {
        const val PASSKEY_ONLY_MESSAGE =
            "This server signs in with passkeys, which Hermex doesn't support yet."
        const val EMPTY_PASSWORD_MESSAGE = "Enter the server password."
    }
}
