package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class MemoryResponse(
    val notes: String? = null,
    @SerialName("user_profile") val userProfile: String? = null,
    @SerialName("notes_mtime") val notesMtime: Double? = null,
    @SerialName("profile_mtime") val profileMtime: Double? = null
)
