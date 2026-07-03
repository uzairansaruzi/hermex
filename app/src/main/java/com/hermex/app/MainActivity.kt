package com.hermex.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.network.ApiClient
import com.hermex.app.ui.navigation.HermesLaunchRequest
import com.hermex.app.ui.navigation.HermexNavHost
import com.hermex.app.ui.notifications.HermexNotificationManager
import com.hermex.app.ui.theme.HermexTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject
    lateinit var authManager: AuthManager

    @Inject
    lateinit var apiClient: ApiClient

    @Inject
    lateinit var notificationManager: HermexNotificationManager

    private var pendingLaunchRequest by mutableStateOf<HermesLaunchRequest?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authManager.serverUrl
            ?.takeIf { it.isNotBlank() }
            ?.let(apiClient::configure)
        pendingLaunchRequest = intent.toHermesLaunchRequest()
        enableEdgeToEdge()
        setContent {
            val isDarkTheme by authManager.isDarkTheme.collectAsState(initial = isSystemInDarkTheme())

            LaunchedEffect(Unit) {
                notificationManager.ensureChannels()
            }

            HermexTheme(darkTheme = isDarkTheme) {
                HermexNavHost(
                    authManager = authManager,
                    pendingLaunchRequest = pendingLaunchRequest,
                    onLaunchRequestConsumed = { pendingLaunchRequest = null }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingLaunchRequest = intent.toHermesLaunchRequest()
    }

    private fun Intent?.toHermesLaunchRequest(): HermesLaunchRequest? {
        if (this == null) return null
        return HermesLaunchRequest.fromParts(
            action = action,
            dataUri = dataString,
            mimeType = type,
            extraText = getStringExtra(Intent.EXTRA_TEXT)
        )
    }
}
