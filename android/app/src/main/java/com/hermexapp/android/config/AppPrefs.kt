package com.hermexapp.android.config

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class ThemeChoice { SYSTEM, LIGHT, DARK }

/** Header Logo Color presets, mirroring the iOS `HeaderLogoColor.presets`. */
enum class AccentPreset(val displayName: String, val hex: String) {
    GOLD("Gold", "#FFD700"),
    BLUE("Blue", "#5B7CFF"),
    PURPLE("Purple", "#AF52DE"),
    RED("Red", "#FF3B30"),
    GREEN("Green", "#34C759"),
    WHITE("White", "#FFFFFF");

    companion object {
        fun fromHex(hex: String?): AccentPreset = entries.firstOrNull { it.hex == hex } ?: GOLD
    }
}

/**
 * Non-secret app preferences (theme, accent color, chat display toggles).
 * Plain SharedPreferences — secrets live in the Keystore-backed SecretStore,
 * never here. Each pref is a StateFlow so the UI reacts immediately.
 */
class AppPrefs(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("hermex_prefs", Context.MODE_PRIVATE)

    private val _theme = MutableStateFlow(
        runCatching { ThemeChoice.valueOf(prefs.getString(KEY_THEME, null) ?: "") }
            .getOrDefault(ThemeChoice.SYSTEM),
    )
    val theme: StateFlow<ThemeChoice> = _theme

    fun setTheme(choice: ThemeChoice) {
        _theme.value = choice
        prefs.edit().putString(KEY_THEME, choice.name).apply()
    }

    /** Header Logo Color — the brand accent (iOS #261). */
    private val _accent = MutableStateFlow(AccentPreset.fromHex(prefs.getString(KEY_ACCENT, null)))
    val accent: StateFlow<AccentPreset> = _accent

    fun setAccent(preset: AccentPreset) {
        _accent.value = preset
        prefs.edit().putString(KEY_ACCENT, preset.hex).apply()
    }

    /** "Expand Thinking by default" (iOS chat display setting). */
    private val _expandThinking = MutableStateFlow(prefs.getBoolean(KEY_EXPAND_THINKING, false))
    val expandThinking: StateFlow<Boolean> = _expandThinking

    fun setExpandThinking(value: Boolean) {
        _expandThinking.value = value
        prefs.edit().putBoolean(KEY_EXPAND_THINKING, value).apply()
    }

    /** "Expand Tool Calls by default". */
    private val _expandTools = MutableStateFlow(prefs.getBoolean(KEY_EXPAND_TOOLS, false))
    val expandTools: StateFlow<Boolean> = _expandTools

    fun setExpandTools(value: Boolean) {
        _expandTools.value = value
        prefs.edit().putBoolean(KEY_EXPAND_TOOLS, value).apply()
    }

    /** Response-completion notifications master switch (default on). */
    private val _notificationsEnabled = MutableStateFlow(prefs.getBoolean(KEY_NOTIFICATIONS, true))
    val notificationsEnabled: StateFlow<Boolean> = _notificationsEnabled

    fun setNotificationsEnabled(value: Boolean) {
        _notificationsEnabled.value = value
        prefs.edit().putBoolean(KEY_NOTIFICATIONS, value).apply()
    }

    private companion object {
        const val KEY_THEME = "theme"
        const val KEY_ACCENT = "accent_hex"
        const val KEY_EXPAND_THINKING = "expand_thinking"
        const val KEY_EXPAND_TOOLS = "expand_tools"
        const val KEY_NOTIFICATIONS = "notifications_enabled"
    }
}
