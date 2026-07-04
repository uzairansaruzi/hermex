package com.hermex.app.data.model

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException

// ─── Responses ───────────────────────────────────────────────────────────────

@Serializable
data class CronsResponse(
    val crons: List<CronJob>? = null,
    val jobs: List<CronJob>? = null
) {
    fun jobList(): List<CronJob> = jobs ?: crons.orEmpty()
}

@Serializable
data class CronMutationResponse(
    val ok: Boolean? = null,
    val job: CronJob? = null,
    val error: String? = null
)

@Serializable
data class CronStatusResponse(
    @SerialName("job_id") val jobId: String? = null,
    @Serializable(with = CronRunningSerializer::class)
    val running: CronRunning? = null,
    @Serializable(with = FlexibleDoubleSerializer::class)
    val elapsed: Double? = null,
    val error: String? = null
)

@Serializable
data class CronOutputResponse(
    @SerialName("job_id") val jobId: String? = null,
    val outputs: List<CronOutputItem>? = null
)

// ─── Core models ─────────────────────────────────────────────────────────────

@Serializable
data class CronJob(
    val id: String? = null,
    @SerialName("job_id") val legacyJobId: String? = null,
    val name: String? = null,
    val prompt: String? = null,
    @Serializable(with = CronScheduleSerializer::class)
    val schedule: CronSchedule? = null,
    @SerialName("schedule_display") val scheduleDisplay: String? = null,
    val enabled: Boolean? = null,
    val state: String? = null,
    @SerialName("next_run_at")
    @Serializable(with = CronTimestampSerializer::class)
    val nextRunAt: Double? = null,
    @SerialName("last_run_at")
    @Serializable(with = CronTimestampSerializer::class)
    val lastRunAt: Double? = null,
    @SerialName("last_status") val lastStatus: String? = null,
    @SerialName("last_error") val lastError: String? = null,
    @SerialName("last_delivery_error") val lastDeliveryError: String? = null,
    @SerialName("repeat") val repeatInfo: CronRepeat? = null,
    val deliver: String? = null,
    val skills: List<String>? = null,
    @Serializable(with = LossyStringSerializer::class)
    val model: String? = null,
    val profile: String? = null,
    @SerialName("toast_notifications") val toastNotifications: Boolean? = null,
    @SerialName("created_at")
    @Serializable(with = CronTimestampSerializer::class)
    val createdAt: Double? = null
) {
    /** Unified job identifier: wire uses `id` in read responses, `job_id` in mutation responses. */
    val jobId: String? get() = id ?: legacyJobId

    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() }
            ?: scheduleText?.takeIf { it.isNotEmpty() }
            ?: "Untitled Task"

    val scheduleText: String?
        get() = scheduleDisplay ?: schedule?.displayText

    val editableScheduleText: String?
        get() = schedule?.expression ?: schedule?.expr ?: schedule?.runAt ?: schedule?.every ?: scheduleDisplay

    val status: CronJobStatus
        get() {
            // Recurring job that completed with no next run and no explicit repeat limit
            if (isRecurring && repeatInfo?.times == null && enabled == false &&
                state == "completed" && nextRunAt == null
            ) return CronJobStatus.NEEDS_ATTENTION

            // Recurring job in error state with no next run
            if (isRecurring && nextRunAt == null &&
                (state == "error" || lastStatus == "error")
            ) return CronJobStatus.NEEDS_ATTENTION

            if (state == "paused") return CronJobStatus.PAUSED
            if (enabled == false) return CronJobStatus.OFF
            if (lastStatus == "error") return CronJobStatus.ERROR

            return CronJobStatus.ACTIVE
        }

    val errorText: String?
        get() = lastError ?: lastDeliveryError

    private val isRecurring: Boolean
        get() = schedule?.kind == "cron" || schedule?.kind == "interval"
}

enum class CronJobStatus {
    ACTIVE, PAUSED, OFF, ERROR, NEEDS_ATTENTION
}

@Serializable
data class CronSchedule(
    val kind: String? = null,
    val expression: String? = null,
    val expr: String? = null,
    @SerialName("run_at") val runAt: String? = null,
    val every: String? = null
) {
    val displayText: String?
        get() = expression ?: expr ?: runAt ?: every ?: kind
}

@Serializable
data class CronRepeat(
    val times: Int? = null,
    val completed: Int? = null
)

@Serializable
data class CronOutputItem(
    val filename: String? = null,
    val content: String? = null
)

@Serializable
data class CronRunning(
    val isRunning: Boolean? = null,
    val jobs: Map<String, Double>? = null
)

// ─── Custom serializers ──────────────────────────────────────────────────────

/**
 * Handles `schedule` values that arrive as either a plain string ("0 7 * * *")
 * or a JSON object ({"kind":"cron","expr":"0 7 * * *"}).
 * Mirrors iOS CronSchedule.init(from:) in Cron.swift:177-194.
 */
object CronScheduleSerializer : KSerializer<CronSchedule?> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(
        "CronSchedule", PrimitiveKind.STRING
    )

    override fun deserialize(decoder: Decoder): CronSchedule? {
        val jsonDecoder = decoder as? JsonDecoder ?: return null
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> {
                // Only accept actual strings, not bare numbers/booleans
                if (!element.isString) return null
                val text = element.contentOrNull ?: return null
                CronSchedule(expression = text)
            }
            is JsonObject -> {
                CronSchedule(
                    kind = element.stringField("kind"),
                    expression = element.stringField("expression"),
                    expr = element.stringField("expr"),
                    runAt = element.stringField("run_at"),
                    every = element.stringField("every")
                )
            }
            else -> null
        }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: CronSchedule?) {
        if (value == null) encoder.encodeNull()
        else encoder.encodeString(value.displayText ?: "")
    }

    private fun JsonObject.stringField(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull
}

/**
 * Handles timestamp values that arrive as epoch numbers, numeric strings,
 * or ISO-8601 date strings. Normalizes to epoch seconds (Double).
 * Mirrors iOS CronDateValue in Cron.swift:357-408.
 */
object CronTimestampSerializer : KSerializer<Double?> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(
        "CronTimestamp", PrimitiveKind.DOUBLE
    )

    override fun deserialize(decoder: Decoder): Double? {
        val jsonDecoder = decoder as? JsonDecoder
            ?: return try { decoder.decodeDouble() } catch (_: Exception) { null }
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> {
                // Try numeric first (epoch seconds)
                element.doubleOrNull?.let { return it }
                // Try numeric string
                val content = element.contentOrNull ?: return null
                content.toDoubleOrNull()?.let { return it }
                // Try ISO-8601
                parseIso8601ToEpochSeconds(content)
            }
            else -> null
        }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: Double?) {
        if (value == null) encoder.encodeNull()
        else encoder.encodeDouble(value)
    }

    private fun parseIso8601ToEpochSeconds(text: String): Double? {
        return try {
            val instant = Instant.parse(text)
            instant.epochSecond.toDouble() + instant.nano / 1_000_000_000.0
        } catch (_: DateTimeParseException) {
            try {
                val odt = OffsetDateTime.parse(text)
                val instant = odt.toInstant()
                instant.epochSecond.toDouble() + instant.nano / 1_000_000_000.0
            } catch (_: DateTimeParseException) {
                null
            }
        }
    }
}

/**
 * Handles `running` values that arrive as either a boolean or a
 * {job_id: elapsed_seconds} map.
 * Mirrors iOS CronStatusResponse.init(from:) in Cron.swift:27-35.
 */
object CronRunningSerializer : KSerializer<CronRunning?> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(
        "CronRunning", PrimitiveKind.STRING
    )

    override fun deserialize(decoder: Decoder): CronRunning? {
        val jsonDecoder = decoder as? JsonDecoder ?: return null
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> {
                val boolVal = element.booleanOrNull ?: return null
                CronRunning(isRunning = boolVal)
            }
            is JsonObject -> {
                val jobs = element.entries.mapNotNull { (key, value) ->
                    val elapsed = (value as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                    key to elapsed
                }.toMap()
                CronRunning(jobs = jobs.ifEmpty { null })
            }
            else -> null
        }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: CronRunning?) {
        if (value == null) {
            encoder.encodeNull()
        } else if (value.isRunning != null) {
            encoder.encodeBoolean(value.isRunning)
        } else {
            encoder.encodeString(value.jobs?.toString() ?: "")
        }
    }
}

/**
 * Accepts any JSON primitive as a string, returns null for non-primitives.
 * Used for fields like `model` which are always strings but sometimes
 * arrive as other types in edge cases.
 */
object LossyStringSerializer : KSerializer<String?> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(
        "LossyString", PrimitiveKind.STRING
    )

    override fun deserialize(decoder: Decoder): String? {
        val jsonDecoder = decoder as? JsonDecoder
            ?: return try { decoder.decodeString() } catch (_: Exception) { null }
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> null
            is JsonPrimitive -> element.contentOrNull
            else -> null
        }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: String?) {
        if (value == null) encoder.encodeNull()
        else encoder.encodeString(value)
    }
}
