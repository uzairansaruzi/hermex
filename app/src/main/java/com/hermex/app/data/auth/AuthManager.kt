package com.hermex.app.data.auth

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

enum class AuthState {
    UNCONFIGURED,
    LOGGED_OUT,
    LOGGED_IN
}

@Singleton
class AuthManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "hermex_auth_prefs",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    private val _authState = MutableStateFlow(determineState())
    val authState: Flow<AuthState> = _authState.asStateFlow()

    val isLoggedIn: Flow<Boolean> = authState.map { it == AuthState.LOGGED_IN }

    val isDarkTheme: Flow<Boolean> = context.getSharedPreferences("hermex_prefs", Context.MODE_PRIVATE)
        .let { sp ->
            kotlinx.coroutines.flow.flow {
                emit(sp.getString("theme", "system") ?: "system")
            }.map { it == "dark" || (it == "system" && isSystemDark()) }
        }

    val serverUrl: String?
        get() = prefs.getString(KEY_SERVER_URL, null)

    fun saveServer(url: String) {
        prefs.edit().putString(KEY_SERVER_URL, url).apply()
        _authState.value = determineState()
    }

    fun savePassword(password: String) {
        prefs.edit().putString(KEY_PASSWORD, password).apply()
    }

    fun getPassword(): String? = prefs.getString(KEY_PASSWORD, null)

    fun clearAuth() {
        prefs.edit().clear().apply()
        _authState.value = AuthState.UNCONFIGURED
    }

    fun markLoggedIn() {
        prefs.edit().putBoolean(KEY_LOGGED_IN, true).apply()
        _authState.value = AuthState.LOGGED_IN
    }

    fun markLoggedOut() {
        prefs.edit().putBoolean(KEY_LOGGED_IN, false).apply()
        _authState.value = determineState()
    }

    private fun determineState(): AuthState {
        val configured = !serverUrl.isNullOrBlank()
        if (!configured) return AuthState.UNCONFIGURED
        return if (prefs.getBoolean(KEY_LOGGED_IN, false)) {
            AuthState.LOGGED_IN
        } else {
            AuthState.LOGGED_OUT
        }
    }

    private fun isSystemDark(): Boolean {
        return (context.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
    }

    companion object {
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_PASSWORD = "password"
        private const val KEY_LOGGED_IN = "logged_in"
    }
}
