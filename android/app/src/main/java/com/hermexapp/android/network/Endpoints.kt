package com.hermexapp.android.network

/**
 * Paths verified against the pinned upstream source (`.codex-tmp/hermes-webui`,
 * `api/routes.py` + `api/auth.py`) — never invented (root AGENTS.md hard rule #1).
 * Mirrors the iOS `Endpoint` enum; grows one entry per endpoint as phases land.
 */
enum class Endpoint(val path: String) {
    HEALTH("/health"),
    AUTH_STATUS("/api/auth/status"),
    LOGIN("/api/auth/login"),
    LOGOUT("/api/auth/logout"),
}
