package com.hermex.app.data.model

import kotlinx.serialization.Serializable

@Serializable
data class CommandsResponse(
    val commands: List<AgentCommand>? = null
)

@Serializable
data class AgentCommand(
    val name: String? = null,
    val description: String? = null,
    val args: String? = null
)

@Serializable
data class PersonalitiesResponse(
    val personalities: List<String>? = null
)
