package com.hermex.app.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.network.ApiClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Thin ViewModel used by [HermexNavHost] to create sessions for
 * [HermesLaunchRequest.NewChat] intents at the nav-host level.
 *
 * This lets the NavHost be the **sole** consumer of launch requests,
 * instead of splitting ownership between NavHost and SessionListScreen.
 */
@HiltViewModel
class LaunchRequestViewModel @Inject constructor(
    private val apiClient: ApiClient
) : ViewModel() {

    fun createSession(
        profileName: String? = null,
        onResult: (sessionId: String) -> Unit
    ) {
        viewModelScope.launch {
            try {
                val response = apiClient.sessionNew(profile = profileName)
                val sessionId = response.session?.sessionId
                if ((response.ok == true || response.session != null) && !sessionId.isNullOrBlank()) {
                    onResult(sessionId)
                }
            } catch (_: Exception) {
                // Session creation failed — the user will see the sessions screen
                // (fallback navigation) and can retry from the FAB.
            }
        }
    }
}
