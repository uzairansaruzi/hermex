package com.hermexapp.android.auth

/**
 * The Android counterpart of the iOS `KeychainStoring` protocol: string secrets
 * by logical key, with optional per-server scoping so one server's credentials
 * are never read or cleared for another. Production uses [KeystoreSecretStore];
 * tests use an in-memory fake.
 */
interface SecretStore {

    enum class Key(val raw: String) {
        SERVER_URL("server_url"),
        // Serialized cookies for one server host (see SessionCookieJar). Always
        // scoped; the unscoped form is never written.
        SESSION_COOKIES("session_cookies"),
    }

    fun save(value: String, key: Key, scope: String? = null)
    fun load(key: Key, scope: String? = null): String?
    fun delete(key: Key, scope: String? = null)

    companion object {
        /**
         * Namespaces a logical key by a server scope. `::` cannot appear in a
         * key's raw value (lowercase identifiers), so it is an unambiguous
         * separator — same convention as the iOS `KeychainStore.scopedKey`.
         */
        fun storageKey(key: Key, scope: String?): String =
            if (scope == null) key.raw else "${key.raw}::$scope"
    }
}

/** In-memory store for tests and previews. */
class InMemorySecretStore : SecretStore {
    private val values = mutableMapOf<String, String>()

    override fun save(value: String, key: SecretStore.Key, scope: String?) {
        values[SecretStore.storageKey(key, scope)] = value
    }

    override fun load(key: SecretStore.Key, scope: String?): String? =
        values[SecretStore.storageKey(key, scope)]

    override fun delete(key: SecretStore.Key, scope: String?) {
        values.remove(SecretStore.storageKey(key, scope))
    }
}
