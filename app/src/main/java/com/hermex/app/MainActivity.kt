package com.hermex.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.network.ApiClient
import com.hermex.app.ui.navigation.HermesLaunchRequest
import com.hermex.app.ui.navigation.HermexNavHost
import com.hermex.app.ui.navigation.LaunchRequestViewModel
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

    private val launchRequestViewModel: LaunchRequestViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authManager.serverUrl
            ?.takeIf { it.isNotBlank() }
            ?.let(apiClient::configure)

        // Only parse the intent on a fresh launch — NOT on configuration change
        // (rotation/theme switch).  On recreation the ViewModel already holds
        // any pending request, and re-parsing the retained intent would submit
        // a duplicate.
        if (savedInstanceState == null) {
            launchRequestViewModel.submit(intent.toHermesLaunchRequest())
        }

        enableEdgeToEdge()
        setContent {
            val isDarkTheme by authManager.isDarkTheme.collectAsState(initial = isSystemInDarkTheme())

            // Request POST_NOTIFICATIONS permission on Android 13+ so
            // response-complete notifications are actually delivered.
            val notificationPermissionLauncher = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.RequestPermission()
            ) { /* granted or denied — no-op, notifications are best-effort */ }

            LaunchedEffect(Unit) {
                notificationManager.ensureChannels()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val granted = ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
            }

            HermexTheme(darkTheme = isDarkTheme) {
                HermexNavHost(
                    authManager = authManager,
                    launchRequestViewModel = launchRequestViewModel
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launchRequestViewModel.submit(intent.toHermesLaunchRequest())
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
