package com.hermex.app.data.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors iOS APIClientCronEndpointTests — verifies tolerant decoding of all
 * cron models against the exact JSON shapes the server returns.
 */
class CronModelsTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    // ─── /api/crons (GET) ────────────────────────────────────────────────────

    @Test
    fun jobsFixtureDecodesWithObjectScheduleIsoDateAndUnknownFields() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            {
              "jobs": [
                {
                  "id": "job123",
                  "name": "Morning digest",
                  "prompt": "Summarize overnight activity",
                  "schedule": {"kind": "cron", "expr": "0 7 * * *", "unexpected": true},
                  "schedule_display": "0 7 * * *",
                  "enabled": true,
                  "state": "scheduled",
                  "next_run_at": "2026-05-05T11:00:00Z",
                  "last_run_at": 1777892400,
                  "last_status": "ok",
                  "deliver": "local",
                  "skills": ["summarize", "notify"],
                  "ignored_new_field": {"nested": "value"}
                },
                {
                  "id": "legacy-broken",
                  "schedule": {"kind": "cron", "expr": "0 8 * * *"},
                  "repeat": {"times": null, "completed": 17},
                  "enabled": false,
                  "state": "completed",
                  "next_run_at": null,
                  "last_status": "ok"
                }
              ]
            }
            """.trimIndent()
        )

        val jobs = decoded.jobList()
        assertEquals(2, jobs.size)

        val first = jobs[0]
        assertEquals("job123", first.jobId)
        assertEquals("Morning digest", first.displayName)
        assertEquals("0 7 * * *", first.scheduleText)
        // ISO-8601 → epoch seconds: 2026-05-05T11:00:00Z
        assertNotNull(first.nextRunAt)
        assertEquals(1_777_978_800.0, first.nextRunAt!!, 0.1)
        assertEquals(1_777_892_400.0, first.lastRunAt!!, 0.1)
        assertEquals(listOf("summarize", "notify"), first.skills)
        assertEquals(CronJobStatus.ACTIVE, first.status)

        val second = jobs[1]
        assertEquals(CronJobStatus.NEEDS_ATTENTION, second.status)
        // displayName falls back to scheduleText when name is null
        assertEquals("0 8 * * *", second.displayName)
        assertNull(second.nextRunAt)
        assertNull(second.repeatInfo?.times)
        assertEquals(17, second.repeatInfo?.completed)
    }

    @Test
    fun createResponseUsesJobIdFallbackAndStringSchedule() {
        val decoded = json.decodeFromString<CronMutationResponse>(
            """
            {
              "ok": true,
              "job": {
                "job_id": "job-new",
                "name": "Morning digest",
                "prompt": "Summarize overnight activity",
                "schedule": "0 7 * * *",
                "enabled": true,
                "state": "scheduled",
                "model": "@openai:gpt-5.5",
                "profile": "work",
                "toast_notifications": true
              }
            }
            """.trimIndent()
        )

        assertEquals(true, decoded.ok)
        val job = decoded.job!!
        assertEquals("job-new", job.jobId)
        assertEquals("0 7 * * *", job.scheduleText)
        assertEquals("@openai:gpt-5.5", job.model)
        assertEquals(true, job.toastNotifications)
        assertEquals("work", job.profile)
    }

    @Test
    fun updateResponseUsesIdKeyAndObjectSchedule() {
        val decoded = json.decodeFromString<CronMutationResponse>(
            """
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Updated digest",
                "prompt": "Updated prompt",
                "schedule": {"kind": "cron", "expr": "0 8 * * *"},
                "enabled": true,
                "state": "scheduled",
                "model": "@anthropic:claude",
                "profile": "personal",
                "toast_notifications": false
              }
            }
            """.trimIndent()
        )

        val job = decoded.job!!
        assertEquals("job123", job.jobId)
        assertEquals("Updated digest", job.displayName)
        assertEquals("0 8 * * *", job.scheduleText)
        assertEquals("@anthropic:claude", job.model)
        assertEquals(false, job.toastNotifications)
    }

    // ─── /api/crons/status (GET) ─────────────────────────────────────────────

    @Test
    fun statusWithRunningMapDecodesJobsAndNullIsRunning() {
        val decoded = json.decodeFromString<CronStatusResponse>(
            """
            {
              "running": {
                "job123": 12.4,
                "job456": 61
              }
            }
            """.trimIndent()
        )

        assertNotNull(decoded.running)
        assertEquals(12.4, decoded.running!!.jobs!!["job123"]!!, 0.01)
        assertEquals(61.0, decoded.running!!.jobs!!["job456"]!!, 0.01)
        assertNull(decoded.running!!.isRunning)
    }

    @Test
    fun statusWithBoolRunningDecodesIsRunningAndNullJobs() {
        val decoded = json.decodeFromString<CronStatusResponse>(
            """
            {
              "job_id": "job123",
              "running": true,
              "elapsed": 12.4
            }
            """.trimIndent()
        )

        assertEquals("job123", decoded.jobId)
        assertEquals(true, decoded.running?.isRunning)
        assertNull(decoded.running?.jobs)
        assertEquals(12.4, decoded.elapsed!!, 0.01)
    }

    // ─── /api/crons/output (GET) ─────────────────────────────────────────────

    @Test
    fun outputsDecodeFilenameAndContent() {
        val decoded = json.decodeFromString<CronOutputResponse>(
            """
            {
              "job_id": "job123",
              "outputs": [
                {
                  "filename": "2026-05-04_10-00-00.md",
                  "content": "## Response\n\nAll clear."
                },
                {
                  "filename": "2026-05-04_09-00-00.md",
                  "content": ""
                }
              ]
            }
            """.trimIndent()
        )

        assertEquals("job123", decoded.jobId)
        assertEquals(2, decoded.outputs!!.size)
        assertEquals("2026-05-04_10-00-00.md", decoded.outputs!![0].filename)
        assertEquals("## Response\n\nAll clear.", decoded.outputs!![0].content)
        assertEquals("2026-05-04_09-00-00.md", decoded.outputs!![1].filename)
        assertEquals("", decoded.outputs!![1].content)
    }

    @Test
    fun emptyOutputsList() {
        val decoded = json.decodeFromString<CronOutputResponse>(
            """
            { "job_id": "job456", "outputs": [] }
            """.trimIndent()
        )

        assertEquals(0, decoded.outputs!!.size)
    }

    // ─── Garbage / tolerance ─────────────────────────────────────────────────

    @Test
    fun garbageScheduleValueDecodesToNull() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "schedule": 42 }] }
            """.trimIndent()
        )
        // numeric non-string schedule → null (no crash)
        assertNull(decoded.jobList().single().schedule)
    }

    @Test
    fun garbageTimestampValueDecodesToNull() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "next_run_at": true, "last_run_at": [1,2,3] }] }
            """.trimIndent()
        )
        val job = decoded.jobList().single()
        assertNull(job.nextRunAt)
        assertNull(job.lastRunAt)
    }

    @Test
    fun garbageRunningValueDecodesToNull() {
        val decoded = json.decodeFromString<CronStatusResponse>(
            """
            { "running": "weird" }
            """.trimIndent()
        )
        // string that isn't a bool → isRunning null, jobs null
        assertNull(decoded.running?.isRunning)
        assertNull(decoded.running?.jobs)
    }

    @Test
    fun unknownFieldsAreIgnored() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "brand_new_field": {"complex": true}, "another": 99 }] }
            """.trimIndent()
        )
        assertEquals("x", decoded.jobList().single().jobId)
    }

    // ─── Status enum logic ───────────────────────────────────────────────────

    @Test
    fun statusEnumPausedState() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "enabled": true, "state": "paused" }] }
            """.trimIndent()
        )
        assertEquals(CronJobStatus.PAUSED, decoded.jobList().single().status)
    }

    @Test
    fun statusEnumDisabledIsOff() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "enabled": false, "state": "scheduled" }] }
            """.trimIndent()
        )
        assertEquals(CronJobStatus.OFF, decoded.jobList().single().status)
    }

    @Test
    fun statusEnumLastStatusErrorIsError() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "enabled": true, "state": "scheduled", "last_status": "error" }] }
            """.trimIndent()
        )
        assertEquals(CronJobStatus.ERROR, decoded.jobList().single().status)
    }

    @Test
    fun statusEnumActiveByDefault() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "enabled": true, "state": "scheduled", "last_status": "ok" }] }
            """.trimIndent()
        )
        assertEquals(CronJobStatus.ACTIVE, decoded.jobList().single().status)
    }

    // ─── CronTimestampSerializer specific ────────────────────────────────────

    @Test
    fun timestampAsNumericString() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "last_run_at": "1777892400.5" }] }
            """.trimIndent()
        )
        assertEquals(1_777_892_400.5, decoded.jobList().single().lastRunAt!!, 0.01)
    }

    @Test
    fun timestampAsIsoWithOffset() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "next_run_at": "2026-05-05T13:00:00+02:00" }] }
            """.trimIndent()
        )
        // +02:00 → same as 11:00:00Z → epoch 1777978800
        assertEquals(1_777_978_800.0, decoded.jobList().single().nextRunAt!!, 0.1)
    }

    // ─── displayName fallback ────────────────────────────────────────────────

    @Test
    fun displayNameFallsBackToScheduleText() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "schedule_display": "Every 5 min" }] }
            """.trimIndent()
        )
        assertEquals("Every 5 min", decoded.jobList().single().displayName)
    }

    @Test
    fun displayNameFallsBackToUntitledTask() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x" }] }
            """.trimIndent()
        )
        assertEquals("Untitled Task", decoded.jobList().single().displayName)
    }

    // ─── LossyStringSerializer for model ─────────────────────────────────────

    @Test
    fun modelDecodesAsStringFromPrimitive() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "model": "@custom:cline-pass:deepseek-v3" }] }
            """.trimIndent()
        )
        assertEquals("@custom:cline-pass:deepseek-v3", decoded.jobList().single().model)
    }

    @Test
    fun modelDecodesToNullFromObject() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "x", "model": {"name": "gpt4"} }] }
            """.trimIndent()
        )
        assertNull(decoded.jobList().single().model)
    }

    // ─── CronsResponse dual-key tolerance ────────────────────────────────────

    @Test
    fun cronsResponseReadsCronsKeyFallback() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "crons": [{ "id": "a" }] }
            """.trimIndent()
        )
        assertEquals("a", decoded.jobList().single().jobId)
    }

    @Test
    fun cronsResponsePrefersJobsOverCrons() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            { "jobs": [{ "id": "from_jobs" }], "crons": [{ "id": "from_crons" }] }
            """.trimIndent()
        )
        assertEquals("from_jobs", decoded.jobList().single().jobId)
    }
}
