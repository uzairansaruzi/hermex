package com.hermexapp.android.network

import com.hermexapp.android.auth.SecretStore
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Holds the server's `hermes_session` auth cookie (upstream `api/auth.py`,
 * COOKIE_NAME) and persists it through the [SecretStore] so login survives
 * process death — the Android counterpart of the iOS shared
 * `HTTPCookieStorage`. Cookies are scoped by host so signing out of one server
 * never clears another's session (mirrors iOS `clearSessionCookies(for:)`).
 *
 * Only cookies are stored, never the password — same rule as iOS.
 */
class SessionCookieJar(private val secretStore: SecretStore) : CookieJar {

    private val cookiesByHost = mutableMapOf<String, MutableMap<String, Cookie>>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (cookies.isEmpty()) return
        val jar = cookiesByHost.getOrPut(url.host) { mutableMapOf() }
        val now = System.currentTimeMillis()
        for (cookie in cookies) {
            if (cookie.expiresAt <= now) jar.remove(cookie.name) else jar[cookie.name] = cookie
        }
        persist(url.host)
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        hydrate(url)
        val jar = cookiesByHost[url.host] ?: return emptyList()
        val now = System.currentTimeMillis()
        jar.values.removeAll { it.expiresAt <= now }
        return jar.values.filter { it.matches(url) }
    }

    /** Drops one host's cookies (sign-out / session expiry), leaving others intact. */
    @Synchronized
    fun clear(host: String) {
        cookiesByHost.remove(host)
        secretStore.delete(SecretStore.Key.SESSION_COOKIES, scope = host)
    }

    private fun persist(host: String) {
        val jar = cookiesByHost[host].orEmpty()
        if (jar.isEmpty()) {
            secretStore.delete(SecretStore.Key.SESSION_COOKIES, scope = host)
            return
        }
        // Serialize via OkHttp's own canonical Set-Cookie string round-trip so we
        // never invent a cookie format of our own.
        val lines = jar.values.joinToString(separator = "\n") { it.toString() }
        secretStore.save(lines, SecretStore.Key.SESSION_COOKIES, scope = host)
    }

    private fun hydrate(url: HttpUrl) {
        if (cookiesByHost.containsKey(url.host)) return
        val stored = secretStore.load(SecretStore.Key.SESSION_COOKIES, scope = url.host) ?: run {
            cookiesByHost[url.host] = mutableMapOf()
            return
        }
        val jar = mutableMapOf<String, Cookie>()
        for (line in stored.lineSequence()) {
            if (line.isBlank()) continue
            Cookie.parse(url, line)?.let { jar[it.name] = it }
        }
        cookiesByHost[url.host] = jar
    }
}
