package com.hermex.app.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Navigation event emitted by [LaunchRequestViewModel].  Collected in
 * [HermexNavHost] to trigger navigation without capturing the
 * [NavHostController] in a ViewModel callback.
 */
sealed interface LaunchNavEvent {
    data class OpenChat(
        val sessionId: String,
        val initialDraft: String = "",
        val autoStartVoice: Boolean = false
    ) : LaunchNavEvent
}

/**
 * Owns pending launch-request state and emits one-shot [LaunchNavEvent]s.
 *
 * Activity-scoped (Hilt default for `@HiltViewModel` obtained via
 * `by viewModels()`).  The same instance is resolved by `hiltViewModel()`
 * inside [HermexNavHost], so `submit()` from [MainActivity] and
 * `dispatch()` from the composable operate on shared state.
 *
 * Uses [Channel.BUFFERED] so an event emitted during a configuration change
 * (collector temporarily detached) is buffered and delivered when the new
 * collector attaches — no event loss.
 */
@HiltViewModel
class LaunchRequestViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {

    private val _pendingRequest = MutableStateFlow<HermesLaunchRequest?>(null)
    val pendingRequest: StateFlow<HermesLaunchRequest?> = _pendingRequest.asStateFlow()

    private val _navEvents = Channel<LaunchNavEvent>(Channel.BUFFERED)
    val navEvents: Flow<LaunchNavEvent> = _navEvents.receiveAsFlow()

    private var createInFlight = false

    /** Called by [MainActivity] to hand off an intent-derived launch request. */
    fun submit(request: HermesLaunchRequest?) {
        if (request != null) _pendingRequest.value = request
    }

    /**
     * Called by [HermexNavHost] once `authState == LOGGED_IN`.
     * Consumes the pending request synchronously; async session creation
     * continues in [viewModelScope] and emits a nav event on completion.
     */
    fun dispatch(request: HermesLaunchRequest) {
        _pendingRequest.value = null
        when (request) {
            is HermesLaunchRequest.OpenSession -> {
                _navEvents.trySend(LaunchNavEvent.OpenChat(request.sessionId))
            }
            is HermesLaunchRequest.NewChat -> {
                if (createInFlight) return
                createInFlight = true
                viewModelScope.launch {
                    try {
                        val response = apiClient.sessionNew(profile = request.profileName)
                        val sessionId = response.session?.sessionId
                        if ((response.ok == true || response.session != null) && !sessionId.isNullOrBlank()) {
                            _navEvents.send(
                                LaunchNavEvent.OpenChat(
                                    sessionId = sessionId,
                                    initialDraft = request.initialDraft,
                                    autoStartVoice = request.autoStartVoice
                                )
                            )
                        }
                    } catch (_: Exception) {
                        // Session creation failed — the user will see the sessions
                        // screen (fallback) and can retry from the FAB.
                    } finally {
                        createInFlight = false
                    }
                }
            }
        }
    }
}
