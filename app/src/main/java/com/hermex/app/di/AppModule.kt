package com.hermex.app.di

import android.content.Context
import com.hermex.app.data.persistence.AppDatabase
import com.hermex.app.data.persistence.MessageDao
import com.hermex.app.data.persistence.SessionDao
import com.hermex.app.data.persistence.provideDatabase as createAppDatabase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import com.hermex.app.data.network.HermesAuthenticator
import com.hermex.app.data.network.LocalCleartextInterceptor
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Provides
    @Singleton
    fun provideCookieJar(): CookieJar = object : CookieJar {
        // B1 fix: merge by cookie name instead of clobbering the entire list.
        // A response setting only one cookie (e.g. CSRF token) must not wipe
        // the existing session cookie for the same host.
        private val cookieStore = ConcurrentHashMap<String, ConcurrentHashMap<String, Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            val hostMap = cookieStore.getOrPut(url.host) { ConcurrentHashMap() }
            for (cookie in cookies) {
                if (cookie.expiresAt <= System.currentTimeMillis()) {
                    hostMap.remove(cookie.name)
                } else {
                    hostMap[cookie.name] = cookie
                }
            }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            return cookieStore[url.host]?.values?.toList().orEmpty()
        }
    }

    @Provides
    @Singleton
    fun provideOkHttpClient(
        cookieJar: CookieJar,
        authenticator: HermesAuthenticator
    ): OkHttpClient {
        return OkHttpClient.Builder()
            .addInterceptor(LocalCleartextInterceptor())
            .authenticator(authenticator)
            .cookieJar(cookieJar)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS) // Long for SSE
            .writeTimeout(30, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase {
        return createAppDatabase(context)
    }

    @Provides
    fun provideSessionDao(db: AppDatabase): SessionDao = db.sessionDao()

    @Provides
    fun provideMessageDao(db: AppDatabase): MessageDao = db.messageDao()
}
