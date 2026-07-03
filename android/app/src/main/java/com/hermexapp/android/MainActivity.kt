package com.hermexapp.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.hermexapp.android.auth.AuthManager
import com.hermexapp.android.features.chat.ChatScreen
import com.hermexapp.android.features.chat.ChatViewModel
import com.hermexapp.android.features.onboarding.OnboardingScreen
import com.hermexapp.android.features.onboarding.OnboardingViewModel
import com.hermexapp.android.features.sessionlist.SessionListScreen
import com.hermexapp.android.features.sessionlist.SessionListViewModel
import kotlinx.coroutines.launch
import okhttp3.HttpUrl

class MainActivity : ComponentActivity() {

    private val onboardingViewModel: OnboardingViewModel by viewModels {
        val container = (application as HermexApp).container
        viewModelFactory {
            initializer {
                OnboardingViewModel(
                    authGateway = container.authManager,
                    savedServerUrl = container.authManager.state.value.server?.toString(),
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as HermexApp).container
        setContent {
            HermexTheme {
                val authState by container.authManager.state.collectAsState()
                when (val state = authState) {
                    is AuthManager.State.LoggedIn ->
                        ConnectedRoot(container, state.server)
                    else -> OnboardingScreen(onboardingViewModel)
                }
            }
        }
    }
}

/**
 * State-based navigation between the session list and one open chat — no
 * navigation dependency (the list is locked); predictive back is handled with
 * [BackHandler].
 */
@Composable
private fun ConnectedRoot(container: AppContainer, server: HttpUrl) {
    val scope = rememberCoroutineScope()
    var openSessionId by remember(server) { mutableStateOf<String?>(null) }

    val repository = remember(server) { container.sessionRepository(server) }
    val sessionListViewModel = remember(server) {
        SessionListViewModel(
            repository = repository,
            onAuthError = container.authManager::handleApiError,
        ).also { it.refresh() }
    }

    val sessionId = openSessionId
    if (sessionId == null) {
        SessionListScreen(
            viewModel = sessionListViewModel,
            onOpenSession = { openSessionId = it },
            onSignOut = { scope.launch { container.authManager.signOut() } },
        )
    } else {
        val chatViewModel = remember(server, sessionId) {
            ChatViewModel(
                sessionId = sessionId,
                repository = repository,
                client = container.apiClient(server),
                sse = container.sseClient(),
                onAuthError = container.authManager::handleApiError,
            )
        }
        BackHandler { openSessionId = null }
        ChatScreen(viewModel = chatViewModel, onBack = { openSessionId = null })
    }
}

@Composable
fun HermexTheme(content: @Composable () -> Unit) {
    val colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
    MaterialTheme(colorScheme = colorScheme, content = content)
}
