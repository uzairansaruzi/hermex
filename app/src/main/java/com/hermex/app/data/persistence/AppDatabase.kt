package com.hermex.app.data.persistence

import android.content.Context
import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "cached_sessions")
data class CachedSession(
    @PrimaryKey val sessionId: String,
    val title: String?,
    val lastMessageAt: Double?,
    val createdAt: Double?,
    val updatedAt: Double?,
    val pinned: Boolean?,
    val archived: Boolean?,
    val model: String?,
    val modelProvider: String?,
    val profile: String?,
    val workspace: String?,
    val inputTokens: Long?,
    val outputTokens: Long?,
    val estimatedCost: Double?,
    val projectId: String?,
    val projectName: String?,
    val messageCount: Int?,
    val cachedAt: Long = System.currentTimeMillis()
)

@Entity(
    tableName = "cached_messages",
    primaryKeys = ["messageId", "sessionId"]
)
data class CachedMessage(
    val messageId: String,
    val sessionId: String,
    val role: String?,
    val content: String?,
    val timestamp: Double?,
    val name: String?,
    val reasoning: String?,
    val cachedAt: Long = System.currentTimeMillis()
)

@Dao
interface SessionDao {
    @Query("SELECT * FROM cached_sessions ORDER BY pinned DESC, lastMessageAt DESC")
    fun getAllSessions(): Flow<List<CachedSession>>

    @Query("SELECT * FROM cached_sessions WHERE sessionId = :sessionId")
    suspend fun getSession(sessionId: String): CachedSession?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSessions(sessions: List<CachedSession>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSession(session: CachedSession)

    @Query("DELETE FROM cached_sessions WHERE sessionId = :sessionId")
    suspend fun deleteSession(sessionId: String)

    @Query("DELETE FROM cached_sessions")
    suspend fun clearAll()

    @Query("SELECT COUNT(*) FROM cached_sessions")
    suspend fun count(): Int
}

@Dao
interface MessageDao {
    @Query("SELECT * FROM cached_messages WHERE sessionId = :sessionId ORDER BY timestamp ASC")
    fun getMessages(sessionId: String): Flow<List<CachedMessage>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMessages(messages: List<CachedMessage>)

    @Query("DELETE FROM cached_messages WHERE sessionId = :sessionId")
    suspend fun clearSession(sessionId: String)

    @Query("DELETE FROM cached_messages")
    suspend fun clearAll()

    @Query("SELECT COUNT(*) FROM cached_messages")
    suspend fun count(): Int

    @Query("DELETE FROM cached_messages WHERE cachedAt < :threshold")
    suspend fun evictOlderThan(threshold: Long)
}

@Database(entities = [CachedSession::class, CachedMessage::class], version = 1)
abstract class AppDatabase : RoomDatabase() {
    abstract fun sessionDao(): SessionDao
    abstract fun messageDao(): MessageDao
}

fun provideDatabase(context: Context): AppDatabase {
    return Room.databaseBuilder(context, AppDatabase::class.java, "hermex_db")
        .fallbackToDestructiveMigration()
        .build()
}
