package com.hermexapp.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Project shapes verified against pinned upstream `api/routes.py`
// (`/api/projects`, `/api/projects/create|rename|delete`). Tolerant per hard
// rule #3: nullable, defaulted fields decoded with ignoreUnknownKeys.

/** A session folder. `color` is an optional `#RRGGBB` (or #RGB/#RRGGBBAA). */
@Serializable
data class Project(
    @SerialName("project_id") val projectId: String? = null,
    val name: String? = null,
    val color: String? = null,
    val profile: String? = null,
    @SerialName("created_at") val createdAt: Double? = null,
)

/** `GET /api/projects`. */
@Serializable
data class ProjectsResponse(
    val projects: List<Project>? = null,
    @SerialName("all_profiles") val allProfiles: Boolean? = null,
    @SerialName("active_profile") val activeProfile: String? = null,
    @SerialName("other_profile_count") val otherProfileCount: Int? = null,
    val error: String? = null,
)

/** `POST /api/projects/create` and `/api/projects/rename`. */
@Serializable
data class ProjectMutationResponse(
    val ok: Boolean? = null,
    val project: Project? = null,
    val error: String? = null,
)

/** `POST /api/session/branch`. */
@Serializable
data class SessionBranchResponse(
    @SerialName("session_id") val sessionId: String? = null,
    val title: String? = null,
    @SerialName("parent_session_id") val parentSessionId: String? = null,
    val error: String? = null,
)
