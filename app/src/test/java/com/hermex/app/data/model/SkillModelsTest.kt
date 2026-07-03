package com.hermex.app.data.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class SkillModelsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun skillsResponseAcceptsFlatListReturnedByServer() {
        val decoded = json.decodeFromString<SkillsResponse>(
            """
            {
              "skills": [
                {
                  "name": "agenttrace-session-audit",
                  "description": "Audit local AI coding-agent sessions with agenttrace.",
                  "category": null,
                  "disabled": false
                }
              ]
            }
            """.trimIndent()
        )

        val skill = decoded.skills!!.single()
        assertEquals("agenttrace-session-audit", skill.name)
        assertEquals("Audit local AI coding-agent sessions with agenttrace.", skill.description)
    }
}
