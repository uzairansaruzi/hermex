package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class MemoryResponse(
    val memory: String? = null,
    val user: String? = null,
    val soul: String? = null,
    @SerialName("memory_path") val memoryPath: String? = null,
    @SerialName("user_path") val userPath: String? = null,
    @SerialName("soul_path") val soulPath: String? = null,
    @SerialName("memory_mtime") val memoryMtime: Double? = null,
    @SerialName("user_mtime") val userMtime: Double? = null,
    @SerialName("soul_mtime") val soulMtime: Double? = null
) {
    val notes: String? get() = memory
    val userProfile: String? get() = user
}
