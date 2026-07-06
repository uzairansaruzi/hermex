package com.hermex.app.data.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ServerModelsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun workspacesResponseAcceptsObjectEntriesReturnedByServer() {
        val decoded = json.decodeFromString<WorkspacesResponse>(
            """
            {
              "workspaces": [
                {
                  "path": "/Users/christopherwilloughby/workspace",
                  "name": "workspace",
                  "extra_server_field": true
                }
              ]
            }
            """.trimIndent()
        )

        assertEquals("/Users/christopherwilloughby/workspace", decoded.workspaces?.single()?.path)
        assertEquals("workspace", decoded.workspaces?.single()?.name)
    }

    @Test
    fun modelsResponseAcceptsGroupedModelsReturnedByServer() {
        val decoded = json.decodeFromString<ModelsResponse>(
            """
            {
              "active_provider": "xiaomi-token-plan",
              "default_model": "mimo-v2.5-pro",
              "groups": [
                {
                  "provider": "Xiaomi Token Plan",
                  "provider_id": "xiaomi-token-plan",
                  "models": [
                    { "id": "mimo-v2.5-pro", "label": "mimo-v2.5-pro" }
                  ]
                },
                {
                  "provider": "OpenAI Codex",
                  "provider_id": "openai-codex",
                  "models": [
                    { "id": "gpt-5.5", "label": "GPT 5.5" },
                    { "id": "gpt-5.4", "label": "GPT 5.4" }
                  ]
                }
              ]
            }
            """.trimIndent()
        )

        assertEquals("mimo-v2.5-pro", decoded.defaultModel)
        assertEquals("Xiaomi Token Plan", decoded.groups?.first()?.provider)
        assertEquals("xiaomi-token-plan", decoded.groups?.first()?.providerId)
        assertEquals("mimo-v2.5-pro", decoded.groups?.first()?.models?.single()?.id)
        assertEquals("GPT 5.5", decoded.groups?.last()?.models?.first()?.label)
        assertEquals(
            mapOf(
                "xiaomi-token-plan" to listOf("mimo-v2.5-pro"),
                "openai-codex" to listOf("gpt-5.5", "gpt-5.4")
            ),
            decoded.modelsByProvider()
        )
    }

    @Test
    fun sessionResponseAcceptsStructuredMessageContentReturnedByServer() {
        val decoded = json.decodeFromString<SessionResponse>(
            """
            {
              "session": {
                "session_id": "abc",
                "title": "Structured content",
                "messages": [
                  {
                    "role": "assistant",
                    "content": [
                      { "type": "text", "text": "hello" },
                      { "type": "tool_result", "content": "world" }
                    ],
                    "timestamp": 1.0
                  }
                ]
              }
            }
            """.trimIndent()
        )

        assertEquals("hello\n\nworld", decoded.session?.messages?.single()?.content)
    }

    @Test
    fun fileListResponseAcceptsEntriesEnvelopeReturnedByServer() {
        val decoded = json.decodeFromString<FileListResponse>(
            """
            {
              "entries": [
                { "name": "README.md", "path": "/repo/README.md", "type": "file", "size": 12 }
              ]
            }
            """.trimIndent()
        )

        assertEquals("README.md", decoded.entries?.single()?.name)
        assertEquals("/repo/README.md", decoded.entries?.single()?.path)
    }

    @Test
    fun cronsResponseReadsJobsFieldReturnedByServer() {
        val decoded = json.decodeFromString<CronsResponse>(
            """
            {
              "jobs": [
                { "job_id": "job_123", "name": "Daily brief", "enabled": true }
              ]
            }
            """.trimIndent()
        )

        assertEquals("job_123", decoded.jobList().single().jobId)
        assertEquals("Daily brief", decoded.jobList().single().name)
    }

    @Test
    fun sessionResponseDecodesMessagesOffsetForHistoryActions() {
        val decoded = json.decodeFromString<SessionResponse>(
            """
            {
              "session": {
                "session_id": "abc",
                "messages_offset": 42,
                "messages_total": 92,
                "messages": [{ "role": "user", "content": "latest", "timestamp": 1.0 }]
              }
            }
            """.trimIndent()
        )

        assertEquals(42, decoded.session?.messagesOffset)
        assertEquals(92, decoded.session?.messagesTotal)
    }

    @Test
    fun workspaceEntriesTreatDirAndIsDirAsDirectories() {
        val decoded = json.decodeFromString<FileListResponse>(
            """
            {
              "entries": [
                { "name": "src", "path": "/repo/src", "type": "dir" },
                { "name": "linked", "path": "/repo/linked", "type": "file", "is_dir": true },
                { "name": "README.md", "path": "/repo/README.md", "type": "file" }
              ]
            }
            """.trimIndent()
        )

        assertEquals(true, decoded.entries?.get(0)?.isDirectory)
        assertEquals(true, decoded.entries?.get(1)?.isDirectory)
        assertEquals(false, decoded.entries?.get(2)?.isDirectory)
    }

    @Test
    fun memoryResponseDecodesUpstreamFieldNames() {
        val decoded = json.decodeFromString<MemoryResponse>(
            """
            {
              "memory": "agent notes",
              "user": "user profile",
              "soul": "long-term soul",
              "memory_path": "/mem/MEMORY.md",
              "user_path": "/mem/USER.md"
            }
            """.trimIndent()
        )

        assertEquals("agent notes", decoded.notes)
        assertEquals("user profile", decoded.userProfile)
        assertEquals("long-term soul", decoded.soul)
        assertEquals("/mem/MEMORY.md", decoded.memoryPath)
    }
}
