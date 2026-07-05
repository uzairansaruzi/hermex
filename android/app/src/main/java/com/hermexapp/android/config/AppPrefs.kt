package com.hermexapp.android.config

import android.content.Context
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
class AppPrefs(private val store: KeyValueStore) {

    constructor(context: Context) : this(KeyValueStore.forPrefs(context, "hermex_prefs"))

    private val _theme = MutableStateFlow(
        runCatching { ThemeChoice.valueOf(store.getString(KEY_THEME) ?: "") }
            .getOrDefault(ThemeChoice.SYSTEM),
    )
    val theme: StateFlow<ThemeChoice> = _theme

    fun setTheme(choice: ThemeChoice) {
        _theme.value = choice
        store.putString(KEY_THEME, choice.name)
    }

    /** Header Logo Color — the brand accent (iOS #261). */
    private val _accent = MutableStateFlow(AccentPreset.fromHex(store.getString(KEY_ACCENT)))
    val accent: StateFlow<AccentPreset> = _accent

    fun setAccent(preset: AccentPreset) {
        _accent.value = preset
        store.putString(KEY_ACCENT, preset.hex)
    }

    /** "Expand Thinking by default" (iOS chat display setting). */
    private val _expandThinking = MutableStateFlow(store.getBoolean(KEY_EXPAND_THINKING, false))
    val expandThinking: StateFlow<Boolean> = _expandThinking

    fun setExpandThinking(value: Boolean) {
        _expandThinking.value = value
        store.putBoolean(KEY_EXPAND_THINKING, value)
    }

    /** "Expand Tool Calls by default". */
    private val _expandTools = MutableStateFlow(store.getBoolean(KEY_EXPAND_TOOLS, false))
    val expandTools: StateFlow<Boolean> = _expandTools

    fun setExpandTools(value: Boolean) {
        _expandTools.value = value
        store.putBoolean(KEY_EXPAND_TOOLS, value)
    }

    /** Response-completion notifications master switch (default on). */
    private val _notificationsEnabled = MutableStateFlow(store.getBoolean(KEY_NOTIFICATIONS, true))
    val notificationsEnabled: StateFlow<Boolean> = _notificationsEnabled

    fun setNotificationsEnabled(value: Boolean) {
        _notificationsEnabled.value = value
        store.putBoolean(KEY_NOTIFICATIONS, value)
    }

    private companion object {
        const val KEY_THEME = "theme"
        const val KEY_ACCENT = "accent_hex"
        const val KEY_EXPAND_THINKING = "expand_thinking"
        const val KEY_EXPAND_TOOLS = "expand_tools"
        const val KEY_NOTIFICATIONS = "notifications_enabled"
    }
}
