package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SkillsResponse(
    val skills: List<SkillSummary>? = null
)

@Serializable
data class SkillSummary(
    val name: String? = null,
    val description: String? = null,
    val category: String? = null,
    val version: String? = null,
    val author: String? = null,
    val disabled: Boolean? = null
)

@Serializable
data class SkillContentResponse(
    val content: String? = null,
    @SerialName("linked_files") val linkedFiles: Map<String, String>? = null
)
