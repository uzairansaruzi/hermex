package com.hermexapp.android.network

import com.hermexapp.android.auth.InMemorySecretStore
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionCookieJarTest {

    private val url = "https://hermes.example.com/".toHttpUrl()
    private val otherUrl = "https://other.example.org/".toHttpUrl()

    private fun sessionCookie(value: String) = Cookie.Builder()
        .name("hermes_session")
        .value(value)
        .domain(url.host)
        .path("/")
        .httpOnly()
        .build()

    @Test
    fun `cookies persist through the secret store across jar instances`() {
        val store = InMemorySecretStore()
        SessionCookieJar(store).saveFromResponse(url, listOf(sessionCookie("token.sig")))

        // A fresh jar (fresh process) hydrates from the store.
        val revived = SessionCookieJar(store).loadForRequest(url)

        assertEquals(1, revived.size)
        assertEquals("hermes_session", revived[0].name)
        assertEquals("token.sig", revived[0].value)
    }

    @Test
    fun `clearing one host leaves other hosts' cookies intact`() {
        val store = InMemorySecretStore()
        val jar = SessionCookieJar(store)
        jar.saveFromResponse(url, listOf(sessionCookie("token.sig")))
        jar.saveFromResponse(
            otherUrl,
            listOf(
                Cookie.Builder().name("hermes_session").value("other")
                    .domain(otherUrl.host).path("/").build(),
            ),
        )

        jar.clear(url.host)

        assertTrue(jar.loadForRequest(url).isEmpty())
        assertEquals("other", jar.loadForRequest(otherUrl).single().value)
    }

    @Test
    fun `cookies are not sent to a different host`() {
        val jar = SessionCookieJar(InMemorySecretStore())
        jar.saveFromResponse(url, listOf(sessionCookie("token.sig")))

        assertTrue(jar.loadForRequest(otherUrl).isEmpty())
    }
}
