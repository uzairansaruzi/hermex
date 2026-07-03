package com.hermexapp.android

import android.app.Application
import com.hermexapp.android.auth.AuthManager
import com.hermexapp.android.auth.KeystoreSecretStore
import com.hermexapp.android.auth.SecretStore
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.SessionCookieJar
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
        container = AppContainer(KeystoreSecretStore(this))
    }
}

class AppContainer(secretStore: SecretStore) {

    val cookieJar = SessionCookieJar(secretStore)

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .build()

    val authManager = AuthManager(
        secretStore = secretStore,
        cookieJar = cookieJar,
        clientFactory = { baseUrl -> ApiClient(baseUrl, httpClient) },
    )
}
