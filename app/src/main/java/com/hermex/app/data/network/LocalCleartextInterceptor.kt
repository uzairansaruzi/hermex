package com.hermex.app.data.network

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.net.InetAddress

/**
 * Allows plain HTTP only for loopback/private-link self-hosted Hermes endpoints.
 * Public hosts must use HTTPS even if platform cleartext policy is widened later.
 */
class LocalCleartextInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val url = request.url
        if (url.scheme == "http" && !isLocalCleartextHost(url.host)) {
            throw IOException("Plain HTTP is only allowed for local or private-network Hermes servers")
        }
        return chain.proceed(request)
    }
}

internal fun isLocalCleartextHost(host: String): Boolean {
    val normalized = host.trim().trim('[', ']').lowercase()
    if (normalized == "localhost") return true

    return runCatching {
        val address = InetAddress.getByName(normalized)
        address.isAnyLocalAddress ||
            address.isLoopbackAddress ||
            address.isSiteLocalAddress ||
            address.isLinkLocalAddress
    }.getOrDefault(false)
}
