package com.hermexapp.android.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CleartextPolicyTest {

    @Test
    fun `loopback and the emulator host alias are allowed`() {
        assertTrue(CleartextPolicy.allowsCleartext("localhost"))
        assertTrue(CleartextPolicy.allowsCleartext("LOCALHOST"))
        assertTrue(CleartextPolicy.allowsCleartext("127.0.0.1"))
        assertTrue(CleartextPolicy.allowsCleartext("10.0.2.2"))
    }

    @Test
    fun `the tailscale CGNAT range boundaries are exact`() {
        // 100.64.0.0/10 spans 100.64.0.0 – 100.127.255.255.
        assertTrue(CleartextPolicy.allowsCleartext("100.64.0.0"))
        assertTrue(CleartextPolicy.allowsCleartext("100.101.102.103"))
        assertTrue(CleartextPolicy.allowsCleartext("100.127.255.255"))
        assertFalse(CleartextPolicy.allowsCleartext("100.63.255.255"))
        assertFalse(CleartextPolicy.allowsCleartext("100.128.0.0"))
    }

    @Test
    fun `public hosts and other private ranges are refused`() {
        assertFalse(CleartextPolicy.allowsCleartext("hermes.example.com"))
        assertFalse(CleartextPolicy.allowsCleartext("192.168.1.10"))
        assertFalse(CleartextPolicy.allowsCleartext("10.0.0.5"))
        assertFalse(CleartextPolicy.allowsCleartext("100.64.0"))
        assertFalse(CleartextPolicy.allowsCleartext("100.64.0.256"))
    }
}
