package com.hermex.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class CronsResponse(
    val crons: List<CronJob>? = null
)

@Serializable
data class CronJob(
    @SerialName("job_id") val jobId: String? = null,
    val name: String? = null,
    val prompt: String? = null,
    val schedule: String? = null,
    val enabled: Boolean? = null,
    val deliver: String? = null,
    val skills: List<String>? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    @SerialName("last_run_at") val lastRunAt: Double? = null,
    @SerialName("next_run_at") val nextRunAt: Double? = null,
    val model: JsonElement? = null,
    val error: String? = null
)

@Serializable
data class CronStatusResponse(
    val running: Boolean? = null,
    @SerialName("job_id") val jobId: String? = null,
    val started_at: Double? = null
)

@Serializable
data class CronOutputResponse(
    val outputs: List<CronOutput>? = null
)

@Serializable
data class CronOutput(
    val timestamp: Double? = null,
    val output: String? = null,
    val error: String? = null,
    @SerialName("exit_code") val exitCode: Int? = null
)
