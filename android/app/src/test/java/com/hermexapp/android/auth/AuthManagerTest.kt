package com.hermexapp.android.auth

import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.ApiError
import com.hermexapp.android.network.SessionCookieJar
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AuthManagerTest {

    private lateinit var server: MockWebServer
    private lateinit var secretStore: InMemorySecretStore
    private lateinit var cookieJar: SessionCookieJar
    private lateinit var httpClient: OkHttpClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        secretStore = InMemorySecretStore()
        cookieJar = SessionCookieJar(secretStore)
        httpClient = OkHttpClient.Builder().cookieJar(cookieJar).build()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun makeManager() = AuthManager(
        secretStore = secretStore,
        cookieJar = cookieJar,
        clientFactory = { ApiClient(it, httpClient) },
        logoutTimeoutMillis = 2_000,
    )

    private fun serverUrlString() = "http://${server.hostName}:${server.port}"

    @Test
    fun `configure logs in against an auth-enabled server and persists the URL`() = runBlocking {
        enqueueHealthOk()
        enqueueAuthStatus(authEnabled = true)
        server.enqueue(
            json("""{"ok": true}""").addHeader(
                "Set-Cookie",
                "hermes_session=token.sig; HttpOnly; Path=/; SameSite=Lax; Max-Age=2592000",
            ),
        )

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "hunter2")

        assertNull(manager.lastErrorMessage.value)
        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        assertNotNull(secretStore.load(SecretStore.Key.SERVER_URL))
        // Cookie persisted for the server host → login survives process death.
        assertNotNull(secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = server.hostName))
    }

    @Test
    fun `configure with the wrong password reports unauthorized and stays logged out`() = runBlocking {
        enqueueHealthOk()
        enqueueAuthStatus(authEnabled = true)
        // The login handler's failure shape: bad(handler, "Invalid password", 401).
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"Invalid password"}"""))

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "wrong")

        // A 401 login throws Unauthorized before the ok-check (same as the iOS
        // client): the message is surfaced and nothing is persisted.
        assertEquals(ApiError.Unauthorized.userMessage, manager.lastErrorMessage.value)
        assertTrue(manager.state.value !is AuthManager.State.LoggedIn)
        assertNull(secretStore.load(SecretStore.Key.SERVER_URL))
    }

    @Test
    fun `configure against a no-auth server skips login entirely`() = runBlocking {
        enqueueHealthOk()
        enqueueAuthStatus(authEnabled = false)

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "")

        assertNull(manager.lastErrorMessage.value)
        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        // health + auth/status only — no login request.
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `configure requires a password when auth is enabled`() = runBlocking {
        enqueueHealthOk()
        enqueueAuthStatus(authEnabled = true)

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "")

        assertEquals(AuthManager.EMPTY_PASSWORD_MESSAGE, manager.lastErrorMessage.value)
        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
    }

    @Test
    fun `a passkey-only server is reported as unsupported`() = runBlocking {
        enqueueHealthOk()
        server.enqueue(
            json("""{"auth_enabled": true, "logged_in": false, "password_auth_enabled": false}"""),
        )

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "irrelevant")

        assertEquals(AuthManager.PASSKEY_ONLY_MESSAGE, manager.lastErrorMessage.value)
        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
    }

    @Test
    fun `a degraded health status fails the probe`() = runBlocking {
        server.enqueue(json("""{"status": "degraded", "sessions": 0}"""))

        val manager = makeManager()
        manager.configure(serverUrlString(), password = "pw")

        assertNotNull(manager.lastErrorMessage.value)
        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
    }

    @Test
    fun `a saved server restores as optimistically logged in`() {
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)

        val manager = makeManager()

        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        assertEquals(server.hostName, manager.state.value.server?.host)
    }

    @Test
    fun `a 401 demotes to logged out and clears only this server's cookies`() {
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)
        secretStore.save("hermes_session=stale", SecretStore.Key.SESSION_COOKIES, scope = server.hostName)
        secretStore.save("hermes_session=other", SecretStore.Key.SESSION_COOKIES, scope = "other.host")

        val manager = makeManager()
        manager.handleApiError(ApiError.Unauthorized)

        assertTrue(manager.state.value is AuthManager.State.LoggedOut)
        assertNotNull(manager.lastErrorMessage.value)
        assertNull(secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = server.hostName))
        assertNotNull(secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = "other.host"))
        // The server URL survives a session expiry so re-login is one field.
        assertNotNull(secretStore.load(SecretStore.Key.SERVER_URL))
    }

    @Test
    fun `signOut logs out server-side then clears local state`() = runBlocking {
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)
        server.enqueue(json("""{"ok": true}"""))

        val manager = makeManager()
        manager.signOut()

        assertEquals("/api/auth/logout", server.takeRequest().path)
        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
        assertNull(secretStore.load(SecretStore.Key.SERVER_URL))
        assertNull(secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = server.hostName))
    }

    @Test
    fun `signOut still clears local state when the server is unreachable`() = runBlocking {
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)
        server.shutdown()

        val manager = makeManager()
        manager.signOut()

        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
        assertNull(secretStore.load(SecretStore.Key.SERVER_URL))
    }

    @Test
    fun `configure registers the server in the multi-server registry`() = runBlocking {
        val registry = com.hermexapp.android.config.ServerRegistry(
            com.hermexapp.android.config.InMemoryKeyValueStore(),
        )
        enqueueHealthOk()
        enqueueAuthStatus(authEnabled = false) // no-auth server: connects immediately
        val manager = AuthManager(
            secretStore = secretStore,
            cookieJar = cookieJar,
            clientFactory = { ApiClient(it, httpClient) },
            logoutTimeoutMillis = 2_000,
            registry = registry,
        )

        manager.configure(serverUrlString(), password = "")

        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        val registered = registry.servers.value.single().url
        assertEquals(server.hostName, registered.substringAfter("://").substringBefore(':').substringBefore('/'))
    }

    @Test
    fun `switchTo makes a known server active without a network call`() {
        val manager = makeManager()
        manager.switchTo(serverUrlString())
        // No request was consumed — switching is purely local (0 requests seen).
        assertEquals(0, server.requestCount)
        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        assertEquals(server.hostName, manager.state.value.server?.host)
        assertNotNull(secretStore.load(SecretStore.Key.SERVER_URL))
    }

    @Test
    fun `beginAddServer drops to onboarding but keeps saved server and cookies`() {
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)
        secretStore.save("cookie-blob", SecretStore.Key.SESSION_COOKIES, scope = server.hostName)
        val manager = makeManager()

        manager.beginAddServer()

        assertTrue(manager.state.value is AuthManager.State.Unconfigured)
        // Registry + cookies survive so the user can switch back.
        assertNotNull(secretStore.load(SecretStore.Key.SERVER_URL))
        assertNotNull(secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = server.hostName))
    }

    @Test
    fun `forgetServer removes the active server and switches to the next`() = runBlocking {
        val store = com.hermexapp.android.config.InMemoryKeyValueStore()
        val registry = com.hermexapp.android.config.ServerRegistry(store)
        registry.addOrKeep(serverUrlString())          // active (this MockWebServer)
        registry.addOrKeep("https://other.example.com") // fallback
        secretStore.save(serverUrlString(), SecretStore.Key.SERVER_URL)
        server.enqueue(json("""{"ok": true}"""))

        val manager = AuthManager(
            secretStore = secretStore,
            cookieJar = cookieJar,
            clientFactory = { ApiClient(it, httpClient) },
            logoutTimeoutMillis = 2_000,
            registry = registry,
        )
        manager.switchTo(serverUrlString())

        manager.forgetServer(serverUrlString())

        // The active server is gone; the fallback is now active.
        assertTrue(registry.servers.value.none { it.url == serverUrlString() })
        assertTrue(manager.state.value is AuthManager.State.LoggedIn)
        assertEquals("other.example.com", manager.state.value.server?.host)
    }

    private fun enqueueHealthOk() {
        server.enqueue(
            json(
                """
                {"status": "ok", "sessions": 0, "active_streams": 0, "active_runs": 0,
                 "runs": [], "last_run_finished_at": null, "uptime_seconds": 1.0,
                 "accept_loop": {"status": "ok"}}
                """,
            ),
        )
    }

    private fun enqueueAuthStatus(authEnabled: Boolean) {
        server.enqueue(json("""{"auth_enabled": $authEnabled, "logged_in": false}"""))
    }

    private fun json(body: String): MockResponse =
        MockResponse()
            .setResponseCode(200)
            .setHeader("Content-Type", "application/json")
            .setBody(body.trimIndent())
}
