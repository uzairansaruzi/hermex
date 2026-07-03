package com.hermex.app.data.network

import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Test

class ApiClientTest {
    @Test
    fun configureAddsHttpSchemeToBareHostAndPort() {
        val client = ApiClient(
            okHttpClient = OkHttpClient(),
            json = Json { ignoreUnknownKeys = true }
        )

        client.configure("192.168.0.157:8787/")

        assertEquals("http://192.168.0.157:8787", client.baseUrl)
    }

    @Test
    fun configurePreservesExplicitHttpsScheme() {
        val client = ApiClient(
            okHttpClient = OkHttpClient(),
            json = Json { ignoreUnknownKeys = true }
        )

        client.configure("https://hermes.example.com/")

        assertEquals("https://hermes.example.com", client.baseUrl)
    }
}
