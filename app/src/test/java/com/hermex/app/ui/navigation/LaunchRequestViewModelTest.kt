package com.hermex.app.ui.navigation

import com.hermex.app.data.model.SessionMutationResponse
import com.hermex.app.data.model.SessionSummary
import com.hermex.app.data.network.ApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.kotlin.whenever

@OptIn(ExperimentalCoroutinesApi::class)
class LaunchRequestViewModelTest {

    private val testDispatcher = StandardTestDispatcher()
    private lateinit var apiClient: ApiClient
    private lateinit var vm: LaunchRequestViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        apiClient = mock()
        vm = LaunchRequestViewModel(apiClient)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun dispatchOpenSessionEmitsNavEventSynchronously() = runTest {
        vm.dispatch(HermesLaunchRequest.OpenSession("session-42"))

        val event = withTimeout(1000) { vm.navEvents.first() }
        assertEquals("session-42", (event as LaunchNavEvent.OpenChat).sessionId)
        assertNull(vm.pendingRequest.value)
    }

    @Test
    fun dispatchNewChatEmitsNavEventAfterSessionCreation() = runTest {
        whenever(apiClient.sessionNew(profile = "coder")).thenReturn(
            SessionMutationResponse(
                ok = true,
                session = SessionSummary(sessionId = "new-123")
            )
        )

        vm.dispatch(
            HermesLaunchRequest.NewChat(
                profileName = "coder",
                initialDraft = "hello",
                autoStartVoice = true
            )
        )
        assertNull(vm.pendingRequest.value)

        advanceUntilIdle()

        val event = withTimeout(1000) { vm.navEvents.first() } as LaunchNavEvent.OpenChat
        assertEquals("new-123", event.sessionId)
        assertEquals("hello", event.initialDraft)
        assertEquals(true, event.autoStartVoice)
    }

    @Test
    fun eventBufferedAndDeliveredToLateCollector() = runTest {
        // Pre-stub the API call to return immediately.
        whenever(apiClient.sessionNew(profile = null)).thenReturn(
            SessionMutationResponse(ok = true, session = SessionSummary(sessionId = "buffered-1"))
        )

        // Dispatch and let the coroutine complete — no collector is attached yet.
        // Channel.BUFFERED holds the event.
        vm.dispatch(HermesLaunchRequest.NewChat())
        advanceUntilIdle()

        // Now attach a collector — the event should still be delivered.
        val event = withTimeout(1000) { vm.navEvents.first() } as LaunchNavEvent.OpenChat
        assertEquals("buffered-1", event.sessionId)
    }

    @Test
    fun sessionNewThrowsDoesNotCrash() = runTest {
        whenever(apiClient.sessionNew(profile = null)).thenThrow(RuntimeException("network"))

        vm.dispatch(HermesLaunchRequest.NewChat())
        advanceUntilIdle()

        // No crash = success.  The ViewModel should be ready for the next dispatch.
        assertNull(vm.pendingRequest.value)
    }

    @Test
    fun submitPopulatesPendingRequest() {
        val request = HermesLaunchRequest.OpenSession("abc")
        vm.submit(request)
        assertEquals(request, vm.pendingRequest.value)
    }

    @Test
    fun dispatchClearsPendingRequest() {
        vm.submit(HermesLaunchRequest.OpenSession("abc"))
        vm.dispatch(HermesLaunchRequest.OpenSession("abc"))
        assertNull(vm.pendingRequest.value)
    }
}
