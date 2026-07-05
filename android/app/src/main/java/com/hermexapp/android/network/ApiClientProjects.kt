package com.hermexapp.android.network

import com.hermexapp.android.model.ProjectMutationResponse
import com.hermexapp.android.model.ProjectsResponse
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

// Project CRUD, verified against pinned upstream `api/routes.py`
// (`/api/projects`, `/api/projects/create|rename|delete`). Colors are validated
// server-side as `#RGB`…`#RRGGBBAA`; we send the picked preset hex unchanged.

suspend fun ApiClient.projects(): ProjectsResponse = getJson(Endpoint.PROJECTS)

suspend fun ApiClient.createProject(name: String, color: String? = null): ProjectMutationResponse =
    postJson(Endpoint.PROJECTS_CREATE, ApiJson.encodeToString(CreateProjectRequest(name, color)))

suspend fun ApiClient.renameProject(
    projectId: String,
    name: String,
    color: String? = null,
): ProjectMutationResponse =
    postJson(Endpoint.PROJECTS_RENAME, ApiJson.encodeToString(RenameProjectRequest(projectId, name, color)))

suspend fun ApiClient.deleteProject(projectId: String): ProjectMutationResponse =
    postJson(Endpoint.PROJECTS_DELETE, ApiJson.encodeToString(ProjectIdRequest(projectId)))

@Serializable
private data class CreateProjectRequest(
    val name: String,
    val color: String? = null,
)

@Serializable
private data class RenameProjectRequest(
    @SerialName("project_id") val projectId: String,
    val name: String,
    val color: String? = null,
)

@Serializable
private data class ProjectIdRequest(@SerialName("project_id") val projectId: String)
