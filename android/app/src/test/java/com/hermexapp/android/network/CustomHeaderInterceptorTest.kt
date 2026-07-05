package com.hermexapp.android.network

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class CustomHeaderInterceptorTest {

    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.shutdown() }

    @Test
    fun `adds configured headers for the request host only`() = runBlocking {
        val host = server.hostName
        val client = OkHttpClient.Builder()
            .addInterceptor(
                CustomHeaderInterceptor { h ->
                    if (h == host) mapOf("X-Token" to "abc", "CF-Access" to "id") else emptyMap()
                },
            )
            .build()
        val api = ApiClient(server.url("/"), client)

        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"status":"ok"}"""))
        api.health()

        val request = server.takeRequest()
        assertEquals("abc", request.getHeader("X-Token"))
        assertEquals("id", request.getHeader("CF-Access"))
    }

    @Test
    fun `never clobbers headers the request already sets`() = runBlocking {
        val client = OkHttpClient.Builder()
            .addInterceptor(CustomHeaderInterceptor { mapOf("Accept" to "text/plain") })
            .build()
        val api = ApiClient(server.url("/"), client)

        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"status":"ok"}"""))
        api.health()

        // ApiClient sets Accept: application/json; the interceptor must not override it.
        assertEquals("application/json", server.takeRequest().getHeader("Accept"))
    }

    @Test
    fun `no headers when the host has none configured`() = runBlocking {
        val client = OkHttpClient.Builder()
            .addInterceptor(CustomHeaderInterceptor { emptyMap() })
            .build()
        val api = ApiClient(server.url("/"), client)

        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"status":"ok"}"""))
        api.health()

        assertNull(server.takeRequest().getHeader("X-Token"))
    }
}
