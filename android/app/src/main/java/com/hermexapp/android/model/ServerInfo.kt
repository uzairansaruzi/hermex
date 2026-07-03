package com.hermexapp.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Shapes verified against the pinned upstream source (root AGENTS.md hard rule #1):
// `_handle_health` and the `/api/auth/*` handlers in `api/routes.py`. Every field
// is nullable with a default so unknown or renamed upstream fields never crash
// decoding (hard rule #3); ApiClient decodes with `ignoreUnknownKeys = true`.

/** Subset of `GET /health` the app reads — mirrors the iOS `HealthResponse`. */
@Serializable
data class HealthResponse(
    val status: String? = null,
    val sessions: Int? = null,
    @SerialName("active_streams") val activeStreams: Int? = null,
    @SerialName("uptime_seconds") val uptimeSeconds: Double? = null,
)

/** `GET /api/auth/status` — mirrors the iOS `AuthStatusResponse`. */
@Serializable
data class AuthStatusResponse(
    @SerialName("auth_enabled") val authEnabled: Boolean? = null,
    @SerialName("logged_in") val loggedIn: Boolean? = null,
    // Finer-grained capabilities newer servers report. `password_auth_enabled ==
    // false` (and only an explicit false) marks a passkey-only server the app
    // can't sign into; a missing value means "unknown" → treat as password auth.
    @SerialName("password_auth_enabled") val passwordAuthEnabled: Boolean? = null,
    @SerialName("passkeys_enabled") val passkeysEnabled: Boolean? = null,
    @SerialName("passwordless_enabled") val passwordlessEnabled: Boolean? = null,
)

/** `POST /api/auth/login` / `logout` result — mirrors the iOS `LoginResponse`. */
@Serializable
data class LoginResponse(
    val ok: Boolean? = null,
    val message: String? = null,
    val error: String? = null,
)
