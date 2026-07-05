package com.hermexapp.android.network

import com.hermexapp.android.config.ServerRegistry
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Attaches the active server's user-configured custom headers to every outgoing
 * request, looked up by host so each server in the multi-server registry gets
 * only its own headers. Existing headers on the request win (we never clobber
 * `Accept`/`Cache-Control`); we only add headers the request doesn't set.
 */
class CustomHeaderInterceptor(private val registry: ServerRegistry) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val extra = registry.headersForHost(request.url.host)
        if (extra.isEmpty()) return chain.proceed(request)

        val builder = request.newBuilder()
        for ((name, value) in extra) {
            if (request.header(name) == null && name.isNotBlank()) {
                builder.header(name, value)
            }
        }
        return chain.proceed(builder.build())
    }
}
