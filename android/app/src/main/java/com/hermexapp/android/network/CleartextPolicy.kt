package com.hermexapp.android.network

/**
 * The product rule from the iOS app (README "Making the server reachable"):
 * plain HTTP is allowed only toward Tailscale's CGNAT device range
 * (100.64.0.0/10) and local loopback. Android's Network Security Config cannot
 * express a CIDR range, so cleartext is permitted platform-wide
 * (res/xml/network_security_config.xml) and THIS check enforces the real rule
 * in the connection layer — every URL is validated through it before a client
 * is built (Android port plan §2).
 *
 * `10.0.2.2` is the Android emulator's alias for the host machine's loopback —
 * the emulator counterpart of the iOS simulator's `localhost` testing path.
 */
object CleartextPolicy {

    fun allowsCleartext(host: String): Boolean {
        val normalized = host.lowercase()
        if (normalized == "localhost" || normalized == "127.0.0.1" || normalized == "10.0.2.2") {
            return true
        }

        val octets = normalized.split(".").mapNotNull { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false

        return octets[0] == 100 && octets[1] in 64..127
    }
}
