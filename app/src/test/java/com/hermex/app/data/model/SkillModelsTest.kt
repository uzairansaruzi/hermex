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

        val decodedSkills = decoded.skills as Any?
        val skill = when (decodedSkills) {
            is List<*> -> decodedSkills.single() as SkillSummary
            is Map<*, *> -> decodedSkills.values.filterIsInstance<List<*>>().flatten().single() as SkillSummary
            else -> error("Unexpected skills container: $decodedSkills")
        }
        assertEquals("agenttrace-session-audit", skill.name)
        assertEquals("Audit local AI coding-agent sessions with agenttrace.", skill.description)
    }
}
