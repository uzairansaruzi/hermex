package com.hermexapp.android.config

import android.content.Context

/**
 * A tiny persistence seam so the non-secret preference holders ([AppPrefs],
 * [ServerRegistry]) don't depend on `Context` directly — production wraps
 * SharedPreferences, tests use [InMemoryKeyValueStore]. Secrets never go here;
 * they live in the Keystore-backed SecretStore.
 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun getBoolean(key: String, default: Boolean): Boolean
    fun putBoolean(key: String, value: Boolean)

    companion object {
        fun forPrefs(context: Context, name: String): KeyValueStore =
            SharedPrefsKeyValueStore(context, name)
    }
}

/** SharedPreferences-backed store used in production. */
class SharedPrefsKeyValueStore(context: Context, name: String) : KeyValueStore {
    private val prefs = context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
    override fun getBoolean(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    override fun putBoolean(key: String, value: Boolean) { prefs.edit().putBoolean(key, value).apply() }
}

/** In-memory store for tests and previews. */
class InMemoryKeyValueStore : KeyValueStore {
    private val values = mutableMapOf<String, Any>()
    override fun getString(key: String): String? = values[key] as? String
    override fun putString(key: String, value: String) { values[key] = value }
    override fun getBoolean(key: String, default: Boolean): Boolean = values[key] as? Boolean ?: default
    override fun putBoolean(key: String, value: Boolean) { values[key] = value }
}
