package com.hermexapp.android.config

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl

/**
 * One saved server: its normalized base URL and any custom HTTP headers the user
 * attached (e.g. a Cloudflare Access `CF-Access-*` pair, or a reverse-proxy
 * token). Headers are non-secret-ish config, so they live in plain prefs
 * alongside the server list — the session cookie/password stay in the Keystore.
 */
@Serializable
data class ServerEntry(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
)

/**
 * The multi-server registry (iOS multi-server + custom-headers parity). Holds the
 * set of known servers and, per server host, the custom headers to attach to
 * every request. [AuthManager] owns which server is *active*; this only owns the
 * catalog + headers. A `@Volatile` host→headers snapshot lets the OkHttp
 * interceptor read headers without suspending.
 */
class ServerRegistry(private val store: KeyValueStore) {

    constructor(context: Context) : this(KeyValueStore.forPrefs(context, "hermex_servers"))

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _servers = MutableStateFlow(load())
    val servers: StateFlow<List<ServerEntry>> = _servers

    /** Host → headers snapshot for the interceptor (rebuilt on every write). */
    @Volatile
    private var headersByHost: Map<String, Map<String, String>> = snapshotByHost(_servers.value)

    /** Adds a server (or leaves an existing one's headers untouched). */
    fun addOrKeep(url: String) {
        if (_servers.value.none { hostOf(it.url) == hostOf(url) }) {
            update(_servers.value + ServerEntry(url))
        }
    }

    fun remove(url: String) {
        update(_servers.value.filterNot { hostOf(it.url) == hostOf(url) })
    }

    fun setHeaders(url: String, headers: Map<String, String>) {
        val host = hostOf(url)
        val existing = _servers.value.firstOrNull { hostOf(it.url) == host }
        val next = if (existing == null) {
            _servers.value + ServerEntry(url, headers)
        } else {
            _servers.value.map { if (hostOf(it.url) == host) it.copy(headers = headers) else it }
        }
        update(next)
    }

    fun headersFor(url: String): Map<String, String> =
        _servers.value.firstOrNull { hostOf(it.url) == hostOf(url) }?.headers.orEmpty()

    /** Non-suspending lookup for the OkHttp interceptor (by request host). */
    fun headersForHost(host: String): Map<String, String> = headersByHost[host].orEmpty()

    private fun update(next: List<ServerEntry>) {
        _servers.value = next
        headersByHost = snapshotByHost(next)
        store.putString(KEY_SERVERS, json.encodeToString(next))
    }

    private fun load(): List<ServerEntry> {
        val raw = store.getString(KEY_SERVERS) ?: return emptyList()
        return runCatching { json.decodeFromString<List<ServerEntry>>(raw) }.getOrDefault(emptyList())
    }

    private fun snapshotByHost(entries: List<ServerEntry>): Map<String, Map<String, String>> =
        entries.associate { hostOf(it.url) to it.headers }

    /** Host component, tolerant of un-parseable/legacy strings. */
    private fun hostOf(url: String): String =
        runCatching { url.toHttpUrl().host }.getOrNull()
            ?: url.substringAfter("://").substringBefore('/').lowercase()

    private companion object {
        const val KEY_SERVERS = "servers_json"
    }
}
