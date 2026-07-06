package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class HealthResponse(val status: String? = null)

@Serializable
data class AuthStatusResponse(
    @SerialName("auth_enabled") val authEnabled: Boolean? = null
)

@Serializable
data class LoginRequest(val password: String)

@Serializable
data class LoginResponse(val ok: Boolean? = null, val error: String? = null)

@Serializable
data class SettingsResponse(
    @SerialName("webui_version") val webuiVersion: String? = null,
    @SerialName("bot_name") val botName: String? = null,
    val version: String? = null
)

@Serializable
data class ModelsResponse(
    val models: Map<String, List<String>>? = null,
    val groups: List<ModelGroup>? = null,
    @SerialName("default_model") val defaultModel: String? = null,
    @SerialName("active_provider") val activeProvider: String? = null,
    @SerialName("live_models") val liveModels: List<JsonElement>? = null
) {
    fun modelsByProvider(): Map<String, List<String>> {
        val grouped = groups.orEmpty()
            .mapNotNull { group ->
                val provider = group.providerId
                    ?: group.provider
                    ?: return@mapNotNull null
                val modelIds = group.models.orEmpty()
                    .mapNotNull { it.id?.takeIf(String::isNotBlank) }
                provider to modelIds
            }
            .filter { (_, modelIds) -> modelIds.isNotEmpty() }
            .toMap()

        return if (grouped.isNotEmpty()) grouped else models.orEmpty()
    }
}

@Serializable
data class ModelGroup(
    val provider: String? = null,
    @SerialName("provider_id") val providerId: String? = null,
    val models: List<ModelOption>? = null
)

@Serializable
data class ModelOption(
    val id: String? = null,
    val label: String? = null
)

@Serializable
data class ProvidersResponse(
    val providers: List<String>? = null
)

@Serializable
data class ProfilesResponse(
    val profiles: List<ProfileInfo>? = null,
    @SerialName("active_profile") val activeProfile: String? = null
)

@Serializable
data class ProfileInfo(
    val name: String? = null,
    val path: String? = null,
    val active: Boolean? = null
)

@Serializable
data class ReasoningRequest(val effort: String)

@Serializable
data class ReasoningResponse(
    val effort: String? = null,
    val display: String? = null
)

@Serializable
data class WorkspacesResponse(
    val workspaces: List<WorkspaceEntry>? = null
)

@Serializable
data class WorkspaceSuggestResponse(
    val suggestions: List<String>? = null
)

@Serializable
data class UploadResponse(
    val filename: String? = null,
    val path: String? = null,
    val mime: String? = null,
    val size: Long? = null,
    @SerialName("is_image") val isImage: Boolean? = null
)
