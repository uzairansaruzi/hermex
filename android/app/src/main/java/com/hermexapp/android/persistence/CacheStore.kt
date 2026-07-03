package com.hermexapp.android.persistence

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert

/**
 * Offline cache seam (Android port plan phase 3). Values are the raw response
 * JSON keyed by host + resource, so the cache never has its own schema to
 * migrate when upstream shapes change — re-decoding stays as tolerant as the
 * network path. Production uses Room ([RoomCacheStore]); tests use the
 * in-memory fake.
 */
interface CacheStore {
    suspend fun save(key: String, json: String)
    suspend fun load(key: String): String?
    suspend fun delete(key: String)

    companion object {
        fun sessionsKey(host: String) = "sessions::$host"
        fun sessionKey(host: String, sessionId: String) = "session::$host::$sessionId"
    }
}

class InMemoryCacheStore : CacheStore {
    private val values = mutableMapOf<String, String>()
    override suspend fun save(key: String, json: String) { values[key] = json }
    override suspend fun load(key: String): String? = values[key]
    override suspend fun delete(key: String) { values.remove(key) }
}

@Entity(tableName = "cached_payloads")
data class CachedPayload(
    @PrimaryKey val key: String,
    val json: String,
    val fetchedAtMillis: Long,
)

@Dao
interface CachedPayloadDao {
    @Upsert
    suspend fun upsert(payload: CachedPayload)

    @Query("SELECT * FROM cached_payloads WHERE `key` = :key")
    suspend fun get(key: String): CachedPayload?

    @Query("DELETE FROM cached_payloads WHERE `key` = :key")
    suspend fun delete(key: String)
}

@Database(entities = [CachedPayload::class], version = 1, exportSchema = false)
abstract class HermexDatabase : RoomDatabase() {
    abstract fun cachedPayloadDao(): CachedPayloadDao

    companion object {
        fun build(context: Context): HermexDatabase =
            Room.databaseBuilder(context, HermexDatabase::class.java, "hermex.db")
                // The cache is disposable by design (raw JSON blobs): on any
                // schema bump, dropping it just means one extra network fetch.
                .fallbackToDestructiveMigration()
                .build()
    }
}

class RoomCacheStore(private val dao: CachedPayloadDao) : CacheStore {
    override suspend fun save(key: String, json: String) {
        dao.upsert(CachedPayload(key, json, System.currentTimeMillis()))
    }

    override suspend fun load(key: String): String? = dao.get(key)?.json

    override suspend fun delete(key: String) = dao.delete(key)
}
