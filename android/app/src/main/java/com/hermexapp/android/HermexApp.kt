package com.hermexapp.android

import android.app.Application
import android.content.Context
import com.hermexapp.android.auth.AuthManager
import com.hermexapp.android.auth.KeystoreSecretStore
import com.hermexapp.android.auth.SecretStore
import com.hermexapp.android.features.sessionlist.SessionRepository
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.SessionCookieJar
import com.hermexapp.android.network.SseClient
import com.hermexapp.android.persistence.CacheStore
import com.hermexapp.android.persistence.HermexDatabase
import com.hermexapp.android.persistence.RoomCacheStore
import okhttp3.HttpUrl
import okhttp3.OkHttpClient

/**
 * Manual dependency wiring — no DI framework (the dependency list is locked).
 * One process-wide OkHttpClient (with the persistent session cookie jar) and
 * one AuthManager, mirroring the iOS app's shared cookie storage + AuthManager.
 */
class HermexApp : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(KeystoreSecretStore(this), this)
    }
}

class AppContainer(secretStore: SecretStore, context: Context? = null) {

    val cookieJar = SessionCookieJar(secretStore)

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .build()

    val cacheStore: CacheStore = context
        ?.let { RoomCacheStore(HermexDatabase.build(it).cachedPayloadDao()) }
        ?: com.hermexapp.android.persistence.InMemoryCacheStore()

    val authManager = AuthManager(
        secretStore = secretStore,
        cookieJar = cookieJar,
        clientFactory = { baseUrl -> ApiClient(baseUrl, httpClient) },
    )

    fun apiClient(baseUrl: HttpUrl): ApiClient = ApiClient(baseUrl, httpClient)

    fun sessionRepository(baseUrl: HttpUrl): SessionRepository =
        SessionRepository(apiClient(baseUrl), cacheStore)

    fun sseClient(): SseClient = SseClient(httpClient)
}
