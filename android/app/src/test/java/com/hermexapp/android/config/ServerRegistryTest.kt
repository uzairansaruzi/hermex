package com.hermexapp.android.config

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerRegistryTest {

    @Test
    fun `addOrKeep dedupes by host and does not clobber existing headers`() {
        val registry = ServerRegistry(InMemoryKeyValueStore())
        registry.addOrKeep("https://a.example.com")
        registry.setHeaders("https://a.example.com", mapOf("X-Token" to "abc"))

        // Same host (different path) must not add a second entry or wipe headers.
        registry.addOrKeep("https://a.example.com/some/path")

        assertEquals(1, registry.servers.value.size)
        assertEquals(mapOf("X-Token" to "abc"), registry.headersFor("https://a.example.com"))
    }

    @Test
    fun `headers are isolated per host`() {
        val registry = ServerRegistry(InMemoryKeyValueStore())
        registry.setHeaders("https://a.example.com", mapOf("X-A" to "1"))
        registry.setHeaders("https://b.example.com", mapOf("X-B" to "2"))

        assertEquals(mapOf("X-A" to "1"), registry.headersForHost("a.example.com"))
        assertEquals(mapOf("X-B" to "2"), registry.headersForHost("b.example.com"))
        assertTrue(registry.headersForHost("c.example.com").isEmpty())
    }

    @Test
    fun `remove drops the server by host`() {
        val registry = ServerRegistry(InMemoryKeyValueStore())
        registry.addOrKeep("https://a.example.com")
        registry.addOrKeep("https://b.example.com")
        registry.remove("https://a.example.com")

        assertEquals(listOf("https://b.example.com"), registry.servers.value.map { it.url })
        assertTrue(registry.headersForHost("a.example.com").isEmpty())
    }

    @Test
    fun `setHeaders on an unknown host adds the server`() {
        val registry = ServerRegistry(InMemoryKeyValueStore())
        registry.setHeaders("https://new.example.com", mapOf("K" to "v"))
        assertEquals(1, registry.servers.value.size)
        assertEquals("v", registry.headersForHost("new.example.com")["K"])
    }

    @Test
    fun `servers and headers persist across instances on the same store`() {
        val store = InMemoryKeyValueStore()
        ServerRegistry(store).apply {
            addOrKeep("https://a.example.com")
            setHeaders("https://a.example.com", mapOf("X-Token" to "abc"))
        }

        val restored = ServerRegistry(store)
        assertEquals(listOf("https://a.example.com"), restored.servers.value.map { it.url })
        // The @Volatile host snapshot must be rebuilt from disk on construction.
        assertEquals("abc", restored.headersForHost("a.example.com")["X-Token"])
    }

    @Test
    fun `a corrupt persisted blob decodes to an empty registry`() {
        val store = InMemoryKeyValueStore().apply { putString("servers_json", "{ not json") }
        assertTrue(ServerRegistry(store).servers.value.isEmpty())
    }
}
