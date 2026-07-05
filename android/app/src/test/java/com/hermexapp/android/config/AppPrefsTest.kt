package com.hermexapp.android.config

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPrefsTest {

    @Test
    fun `defaults match the iOS baseline`() {
        val prefs = AppPrefs(InMemoryKeyValueStore())
        assertEquals(ThemeChoice.SYSTEM, prefs.theme.value)
        assertEquals(AccentPreset.GOLD, prefs.accent.value)
        assertFalse(prefs.expandThinking.value)
        assertFalse(prefs.expandTools.value)
        assertTrue(prefs.notificationsEnabled.value) // notifications default on
    }

    @Test
    fun `setters update the flow immediately`() {
        val prefs = AppPrefs(InMemoryKeyValueStore())
        prefs.setTheme(ThemeChoice.DARK)
        prefs.setAccent(AccentPreset.PURPLE)
        prefs.setExpandThinking(true)
        prefs.setExpandTools(true)
        prefs.setNotificationsEnabled(false)

        assertEquals(ThemeChoice.DARK, prefs.theme.value)
        assertEquals(AccentPreset.PURPLE, prefs.accent.value)
        assertTrue(prefs.expandThinking.value)
        assertTrue(prefs.expandTools.value)
        assertFalse(prefs.notificationsEnabled.value)
    }

    @Test
    fun `values survive a process restart (re-read from the same store)`() {
        val store = InMemoryKeyValueStore()
        AppPrefs(store).apply {
            setTheme(ThemeChoice.LIGHT)
            setAccent(AccentPreset.GREEN)
            setExpandTools(true)
            setNotificationsEnabled(false)
        }

        val restored = AppPrefs(store)
        assertEquals(ThemeChoice.LIGHT, restored.theme.value)
        assertEquals(AccentPreset.GREEN, restored.accent.value)
        assertTrue(restored.expandTools.value)
        assertFalse(restored.notificationsEnabled.value)
    }

    @Test
    fun `accent preset maps hex tolerantly and falls back to gold`() {
        assertEquals(AccentPreset.BLUE, AccentPreset.fromHex("#5B7CFF"))
        assertEquals(AccentPreset.RED, AccentPreset.fromHex("#FF3B30"))
        assertEquals(AccentPreset.GOLD, AccentPreset.fromHex(null))
        assertEquals(AccentPreset.GOLD, AccentPreset.fromHex("#NOTACOLOR"))
    }

    @Test
    fun `a corrupt persisted theme falls back to SYSTEM`() {
        val store = InMemoryKeyValueStore().apply { putString("theme", "PLAID") }
        assertEquals(ThemeChoice.SYSTEM, AppPrefs(store).theme.value)
    }
}
