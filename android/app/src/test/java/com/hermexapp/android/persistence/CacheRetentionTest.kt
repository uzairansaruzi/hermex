package com.hermexapp.android.persistence

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CacheRetentionTest {

    private val day = 24 * 60 * 60 * 1000L
    private val maxAge = 90 * day

    @Test
    fun `evicts entries older than the max age`() {
        val now = 1_000 * day
        val victims = CacheRetention.victims(
            entries = listOf(
                "sessions::a" to now - 10 * day,   // fresh
                "sessions::b" to now - 200 * day,  // stale
            ),
            nowMillis = now, maxAgeMillis = maxAge, keepTranscripts = 50,
        )
        assertEquals(listOf("sessions::b"), victims)
    }

    @Test
    fun `caps transcripts to the N most-recent, keeping non-transcript keys`() {
        val now = 1_000 * day
        val entries = (1..5).map { "session::h::s$it" to now - it * 1L } +
            ("sessions::h" to now) // a list blob, never capped
        val victims = CacheRetention.victims(entries, now, maxAge, keepTranscripts = 2)

        // Newest two transcripts (s1, s2) survive; s3..s5 are dropped.
        assertEquals(setOf("session::h::s3", "session::h::s4", "session::h::s5"), victims.toSet())
    }

    @Test
    fun `age and cap victims are unioned without duplicates`() {
        val now = 1_000 * day
        val entries = listOf(
            "session::h::old" to now - 200 * day, // both too old AND over cap
            "session::h::new" to now,
        )
        val victims = CacheRetention.victims(entries, now, maxAge, keepTranscripts = 1)
        assertEquals(listOf("session::h::old"), victims)
    }

    @Test
    fun `InMemory prune enforces the same policy end to end`() = runBlocking {
        var clock = 0L
        val cache = InMemoryCacheStore(clock = { clock })

        clock = 0L; cache.save("session::h::a", "{}")           // very old
        clock = 1_000 * day; cache.save("session::h::b", "{}")  // recent
        cache.save("session::h::c", "{}")                       // recent
        cache.save("sessions::h", "{}")                         // list blob, recent

        cache.prune(maxAgeMillis = maxAge, keepTranscripts = 1)

        // 'a' is too old; of the recent transcripts only the newest is kept.
        assertNull(cache.load("session::h::a"))
        assertNotNull(cache.load("sessions::h"))
        val remainingTranscripts = listOf("session::h::b", "session::h::c").count { cache.load(it) != null }
        assertEquals(1, remainingTranscripts)
    }
}
