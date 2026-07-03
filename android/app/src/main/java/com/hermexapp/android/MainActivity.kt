package com.hermexapp.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.hermexapp.android.auth.AuthManager
import com.hermexapp.android.features.onboarding.OnboardingScreen
import com.hermexapp.android.features.onboarding.OnboardingViewModel
import kotlinx.coroutines.launch

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
        val authManager = (application as HermexApp).container.authManager
        setContent {
            HermexTheme {
                val authState by authManager.state.collectAsState()
                when (authState) {
                    is AuthManager.State.LoggedIn -> ConnectedPlaceholderScreen(authManager)
                    else -> OnboardingScreen(onboardingViewModel)
                }
            }
        }
    }
}

@Composable
fun HermexTheme(content: @Composable () -> Unit) {
    val colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
    MaterialTheme(colorScheme = colorScheme, content = content)
}

/** Stand-in home screen until phase 3 (session list) lands. */
@Composable
fun ConnectedPlaceholderScreen(authManager: AuthManager) {
    val scope = rememberCoroutineScope()
    val state by authManager.state.collectAsState()

    Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Connected", style = MaterialTheme.typography.headlineLarge)
            Text(
                state.server?.toString().orEmpty(),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Sessions arrive in phase 3 of the port plan.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = { scope.launch { authManager.signOut() } }) { Text("Sign out") }
        }
    }
}
