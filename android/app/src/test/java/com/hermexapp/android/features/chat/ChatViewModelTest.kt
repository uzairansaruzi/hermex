package com.hermexapp.android.features.chat

import com.hermexapp.android.auth.InMemorySecretStore
import com.hermexapp.android.features.chat.ChatViewModel.TimelineEntry
import com.hermexapp.android.features.sessionlist.SessionRepository
import com.hermexapp.android.network.ApiClient
import com.hermexapp.android.network.SessionCookieJar
import com.hermexapp.android.network.SseEvent
import com.hermexapp.android.network.SseStreaming
import com.hermexapp.android.network.ToolStreamEvent
import com.hermexapp.android.persistence.InMemoryCacheStore
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ChatViewModelTest {

    private class FakeSse : SseStreaming {
        var startedUrl: HttpUrl? = null
        var stopped = false
        private var listener: ((SseEvent) -> Unit)? = null

        override fun start(url: HttpUrl, onEvent: (SseEvent) -> Unit) {
            startedUrl = url
            listener = onEvent
        }

        override fun stop() {
            stopped = true
        }

        fun emit(event: SseEvent) = listener!!.invoke(event)
    }

    private lateinit var server: MockWebServer
    private lateinit var viewModel: ChatViewModel
    private lateinit var sse: FakeSse

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val client = ApiClient(
            baseUrl = server.url("/"),
            httpClient = OkHttpClient.Builder()
                .cookieJar(SessionCookieJar(InMemorySecretStore()))
                .build(),
        )
        sse = FakeSse()
        viewModel = ChatViewModel(
            sessionId = "abc",
            repository = SessionRepository(client, InMemoryCacheStore()),
            client = client,
            sse = sse,
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `load maps the transcript into timeline entries`() = runBlocking {
        server.enqueue(
            json(
                """
                {"session": {"session_id": "abc", "title": "My session", "messages": [
                    {"role": "user", "content": "question", "_ts": 1.0},
                    {"role": "assistant", "content": "answer", "message_id": "m1"},
                    {"role": "user", "content": "", "tool_call_id": "tr1"}
                ]}}
                """,
            ),
        )

        viewModel.loadNow()

        val state = viewModel.uiState.value
        assertEquals("My session", state.title)
        // The empty tool-result row is skipped.
        assertEquals(2, state.entries.size)
        assertEquals("question", (state.entries[0] as TimelineEntry.UserMessage).text)
        assertEquals("answer", (state.entries[1] as TimelineEntry.AssistantMessage).text)
    }

    @Test
    fun `send starts a run and streams tokens into a draft`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1", "session_id": "abc"}"""))
        viewModel.updateComposerText("do the thing")
        viewModel.sendNow()

        assertTrue(viewModel.uiState.value.isStreaming)
        assertEquals("/api/chat/stream?stream_id=st1", sse.startedUrl?.encodedPath + "?" + sse.startedUrl?.encodedQuery)

        sse.emit(SseEvent.Token("Wor"))
        sse.emit(SseEvent.Token("king"))

        val draft = viewModel.uiState.value.entries.last() as TimelineEntry.AssistantMessage
        assertEquals("Working", draft.text)
        assertTrue(draft.isStreaming)

        sse.emit(SseEvent.StreamEnd)
        val state = viewModel.uiState.value
        assertFalse(state.isStreaming)
        assertFalse((state.entries.last() as TimelineEntry.AssistantMessage).isStreaming)
        assertTrue(sse.stopped)
    }

    @Test
    fun `reasoning and tool events build their own entries`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()

        sse.emit(SseEvent.Reasoning("thinking "))
        sse.emit(SseEvent.Reasoning("hard"))
        sse.emit(SseEvent.ToolStarted(ToolStreamEvent(name = "bash", preview = "ls", tid = "t1")))
        sse.emit(SseEvent.Token("done soon"))
        sse.emit(
            SseEvent.ToolCompleted(
                ToolStreamEvent(name = "bash", duration = 0.7, tid = "t1"),
            ),
        )

        val entries = viewModel.uiState.value.entries
        val reasoning = entries.filterIsInstance<TimelineEntry.Reasoning>().single()
        assertEquals("thinking hard", reasoning.text)

        val tool = entries.filterIsInstance<TimelineEntry.ToolCall>().single()
        assertEquals("bash", tool.name)
        assertFalse(tool.isRunning)
        assertEquals(0.7, tool.durationSeconds!!, 0.0001)
        // The completed tool kept its identity (updated in place via tid).
        assertEquals("tool-t1", tool.id)
    }

    @Test
    fun `interim assistant finalizes the streamed draft without duplicating it`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()

        sse.emit(SseEvent.Token("partial answer"))
        sse.emit(SseEvent.InterimAssistant(text = "partial answer", alreadyStreamed = true))
        sse.emit(SseEvent.Token("next segment"))

        val assistants = viewModel.uiState.value.entries.filterIsInstance<TimelineEntry.AssistantMessage>()
        assertEquals(2, assistants.size)
        assertEquals("partial answer", assistants[0].text)
        assertFalse(assistants[0].isStreaming)
        assertEquals("next segment", assistants[1].text)
        assertTrue(assistants[1].isStreaming)
    }

    @Test
    fun `a done event rebuilds the transcript from the authoritative session`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()
        sse.emit(SseEvent.Token("draft text"))

        val sessionJson = """
            {"session_id": "abc", "title": "Final title", "messages": [
                {"role": "user", "content": "go"},
                {"role": "assistant", "content": "the real final answer"}
            ]}
        """.trimIndent()
        sse.emit(SseEvent.Done(com.hermexapp.android.network.ApiJson.parseToJsonElement(sessionJson)))
        sse.emit(SseEvent.StreamEnd)

        val state = viewModel.uiState.value
        assertEquals("Final title", state.title)
        val assistant = state.entries.filterIsInstance<TimelineEntry.AssistantMessage>().single()
        assertEquals("the real final answer", assistant.text)
    }

    @Test
    fun `stream errors end the run and surface the message`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()

        sse.emit(SseEvent.Error("the model provider exploded"))

        val state = viewModel.uiState.value
        assertFalse(state.isStreaming)
        assertEquals("the model provider exploded", state.errorMessage)
        assertTrue(sse.stopped)
    }

    @Test
    fun `sending while streaming steers instead of starting a new run`() = runBlocking {
        server.enqueue(json("""{"stream_id": "st1"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()
        server.takeRequest() // /api/chat/start

        server.enqueue(json("""{"ok": true}"""))
        viewModel.updateComposerText("actually, focus on tests")
        viewModel.sendNow()

        val steer = server.takeRequest()
        assertEquals("/api/chat/steer", steer.path)
        assertEquals(
            """{"session_id":"abc","text":"actually, focus on tests"}""",
            steer.body.readUtf8(),
        )
        // The steer text appears in the timeline as a user message.
        assertNotNull(
            viewModel.uiState.value.entries
                .filterIsInstance<TimelineEntry.UserMessage>()
                .find { it.text == "actually, focus on tests" },
        )
    }

    @Test
    fun `a failed start surfaces the server error`() = runBlocking {
        server.enqueue(json("""{"error": "no such session"}"""))
        viewModel.updateComposerText("go")
        viewModel.sendNow()

        assertEquals("no such session", viewModel.uiState.value.errorMessage)
        assertFalse(viewModel.uiState.value.isStreaming)
    }

    private fun json(body: String): MockResponse =
        MockResponse()
            .setResponseCode(200)
            .setHeader("Content-Type", "application/json")
            .setBody(body.trimIndent())
}
