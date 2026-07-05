package com.hermexapp.android

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.Crossfade
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.hermexapp.android.auth.AuthManager
import com.hermexapp.android.config.AccentPreset
import com.hermexapp.android.config.ThemeChoice
import com.hermexapp.android.features.chat.ChatDisplayPrefs
import com.hermexapp.android.features.chat.ChatScreen
import com.hermexapp.android.features.chat.ChatViewModel
import com.hermexapp.android.features.chat.LocalChatDisplayPrefs
import com.hermexapp.android.features.onboarding.OnboardingScreen
import com.hermexapp.android.features.onboarding.OnboardingViewModel
import com.hermexapp.android.features.panels.PanelKind
import com.hermexapp.android.features.panels.PanelScreen
import com.hermexapp.android.features.panels.PanelsViewModel
import com.hermexapp.android.features.sessionlist.SessionListScreen
import com.hermexapp.android.features.sessionlist.SessionListViewModel
import com.hermexapp.android.features.settings.SettingsScreen
import com.hermexapp.android.features.workspace.FileBrowserScreen
import com.hermexapp.android.features.workspace.GitScreen
import com.hermexapp.android.features.workspace.WorkspaceViewModel
import com.hermexapp.android.platform.RunNotifications
import com.hermexapp.android.ui.theme.HermexTheme
import com.hermexapp.android.ui.theme.accentColorFromHex
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

    private val notificationPermissionRequest =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as HermexApp).container
        handleIncomingIntent(intent)
        requestNotificationPermissionIfNeeded()

        setContent {
            val themeChoice by (container.prefs?.theme
                ?: kotlinx.coroutines.flow.MutableStateFlow(ThemeChoice.SYSTEM)).collectAsState()
            val accent by (container.prefs?.accent
                ?: kotlinx.coroutines.flow.MutableStateFlow(AccentPreset.GOLD)).collectAsState()
            val expandThinking by (container.prefs?.expandThinking
                ?: kotlinx.coroutines.flow.MutableStateFlow(false)).collectAsState()
            val expandTools by (container.prefs?.expandTools
                ?: kotlinx.coroutines.flow.MutableStateFlow(false)).collectAsState()
            HermexTheme(themeChoice, accentColorFromHex(accent.hex)) {
                androidx.compose.runtime.CompositionLocalProvider(
                    LocalChatDisplayPrefs provides ChatDisplayPrefs(expandThinking, expandTools),
                ) {
                    val authState by container.authManager.state.collectAsState()
                    when (val state = authState) {
                        is AuthManager.State.LoggedIn -> ConnectedRoot(container, state.server)
                        else -> OnboardingScreen(onboardingViewModel)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    /** Share-target text and notification taps park in the shared draft / extras. */
    private fun handleIncomingIntent(intent: Intent?) {
        intent ?: return
        val container = (application as HermexApp).container
        when {
            intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true ->
                container.sharedDraftStore.offer(intent.getStringExtra(Intent.EXTRA_TEXT))
            intent.action == Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
                container.sharedDraftStore.offer(
                    text = intent.getStringExtra(Intent.EXTRA_TEXT),
                    fileUris = listOfNotNull(uri?.toString()),
                )
            }
            intent.action == Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val uris = intent.getParcelableArrayListExtra<android.net.Uri>(Intent.EXTRA_STREAM)
                container.sharedDraftStore.offer(
                    text = intent.getStringExtra(Intent.EXTRA_TEXT),
                    fileUris = uris.orEmpty().map { it.toString() },
                )
            }
            intent.hasExtra(RunNotifications.EXTRA_SESSION_ID) ->
                pendingSessionFromNotification = intent.getStringExtra(RunNotifications.EXTRA_SESSION_ID)
            intent.getBooleanExtra(com.hermexapp.android.platform.HermexWidgetProvider.EXTRA_NEW_CHAT, false) ->
                pendingNewChatFromWidget = true
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33) {
            notificationPermissionRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    companion object {
        /** Session to open when launched from a run-complete notification. */
        var pendingSessionFromNotification: String? = null

        /** Set when launched from the home-screen widget's "New chat" button. */
        var pendingNewChatFromWidget: Boolean = false
    }
}

private sealed class Screen {
    data object SessionList : Screen()
    data class Chat(val sessionId: String) : Screen()
    data class Files(val sessionId: String) : Screen()
    data class Git(val sessionId: String) : Screen()
    data class Panel(val kind: PanelKind) : Screen()
    data object Settings : Screen()
    data object Projects : Screen()
}

@Composable
private fun ConnectedRoot(container: AppContainer, server: HttpUrl) {
    val scope = rememberCoroutineScope()
    var screen by remember(server) { mutableStateOf<Screen>(Screen.SessionList) }

    val repository = remember(server) { container.sessionRepository(server) }
    val client = remember(server) { container.apiClient(server) }
    val sessionListViewModel = remember(server) {
        SessionListViewModel(
            repository = repository,
            onAuthError = container.authManager::handleApiError,
        ).also { it.refresh() }
    }

    // A shared text or image (ACTION_SEND) becomes a fresh chat with the
    // composer prefilled (and the image uploaded + attached).
    val pendingShare by container.sharedDraftStore.pending.collectAsState()
    val context = LocalContext.current
    LaunchedEffect(pendingShare) {
        if (pendingShare != null) {
            val content = container.sharedDraftStore.consume() ?: return@LaunchedEffect
            val sessionId = sessionListViewModel.createSessionNow() ?: return@LaunchedEffect
            sharePrefill = content.text
            shareFileUploads = content.fileUris.mapNotNull { uriString ->
                runCatching {
                    val uri = android.net.Uri.parse(uriString)
                    val bytes = withContext(Dispatchers.IO) {
                        context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    }
                    val name = resolveDisplayName(context, uri)
                    bytes?.let { it to name }
                }.getOrNull()
            }
            screen = Screen.Chat(sessionId)
        }
    }

    // A notification tap deep-links straight into its session.
    LaunchedEffect(Unit) {
        MainActivity.pendingSessionFromNotification?.let {
            MainActivity.pendingSessionFromNotification = null
            screen = Screen.Chat(it)
        }
        // The widget's "New chat" button opens a fresh session on launch.
        if (MainActivity.pendingNewChatFromWidget) {
            MainActivity.pendingNewChatFromWidget = false
            sessionListViewModel.createSessionNow()?.let { screen = Screen.Chat(it) }
        }
    }

    Crossfade(targetState = screen, label = "screens") { current ->
        when (current) {
            Screen.SessionList -> SessionListScreen(
                viewModel = sessionListViewModel,
                onOpenSession = { screen = Screen.Chat(it) },
                onOpenPanel = { kind -> screen = Screen.Panel(PanelKind.valueOf(kind)) },
                onOpenSettings = { screen = Screen.Settings },
                onOpenProjects = { screen = Screen.Projects },
            )

            Screen.Projects -> {
                BackHandler { screen = Screen.SessionList }
                com.hermexapp.android.features.sessionlist.ProjectsScreen(
                    viewModel = sessionListViewModel,
                    onOpenSession = { screen = Screen.Chat(it) },
                    onClose = { screen = Screen.SessionList },
                )
            }

            is Screen.Chat -> {
                val appContext = LocalContext.current.applicationContext
                val chatViewModel = remember(server, current.sessionId) {
                    ChatViewModel(
                        sessionId = current.sessionId,
                        repository = repository,
                        client = client,
                        sse = container.sseClient(),
                        onAuthError = container.authManager::handleApiError,
                    ).also { vm ->
                        sharePrefill?.let { vm.updateComposerText(it); sharePrefill = null }
                        if (shareFileUploads.isNotEmpty()) {
                            val uploads = shareFileUploads
                            shareFileUploads = emptyList()
                            vm.viewModelScope.launch {
                                uploads.forEach { (bytes, name) -> vm.addAttachmentNow(bytes, name) }
                            }
                        }
                    }
                }
                val chatState by chatViewModel.uiState.collectAsState()
                // Ongoing-run foreground service: alive only while streaming.
                LaunchedEffect(chatState.isStreaming) {
                    if (chatState.isStreaming) {
                        com.hermexapp.android.platform.ActiveRunService.start(appContext, chatState.title)
                    } else {
                        com.hermexapp.android.platform.ActiveRunService.stop(appContext)
                    }
                }
                BackHandler { screen = Screen.SessionList }
                ChatScreen(
                    viewModel = chatViewModel,
                    onBack = { screen = Screen.SessionList },
                    onOpenFiles = { screen = Screen.Files(current.sessionId) },
                    onOpenGit = { screen = Screen.Git(current.sessionId) },
                    onRunFinished = { title ->
                        if (container.prefs?.notificationsEnabled?.value != false) {
                            container.notifications?.notifyRunComplete(title, current.sessionId)
                        }
                    },
                )
            }

            is Screen.Files -> {
                val workspaceViewModel = remember(server, current.sessionId, "files") {
                    WorkspaceViewModel(current.sessionId, client, container.authManager::handleApiError)
                }
                FileBrowserScreen(
                    viewModel = workspaceViewModel,
                    onClose = { screen = Screen.Chat(current.sessionId) },
                )
            }

            is Screen.Git -> {
                val workspaceViewModel = remember(server, current.sessionId, "git") {
                    WorkspaceViewModel(current.sessionId, client, container.authManager::handleApiError)
                }
                GitScreen(
                    viewModel = workspaceViewModel,
                    onClose = { screen = Screen.Chat(current.sessionId) },
                )
            }

            is Screen.Panel -> {
                val panelsViewModel = remember(server, current.kind) {
                    PanelsViewModel(client, container.authManager::handleApiError)
                }
                BackHandler { screen = Screen.SessionList }
                PanelScreen(
                    kind = current.kind,
                    viewModel = panelsViewModel,
                    onClose = { screen = Screen.SessionList },
                )
            }

            Screen.Settings -> {
                BackHandler { screen = Screen.SessionList }
                SettingsScreen(
                    client = client,
                    prefs = container.prefs ?: return@Crossfade,
                    serverUrl = server.toString(),
                    onSignOut = { scope.launch { container.authManager.signOut() } },
                    onClose = { screen = Screen.SessionList },
                    registry = container.serverRegistry,
                    onSwitchServer = { container.authManager.switchTo(it) },
                    onAddServer = { container.authManager.beginAddServer() },
                    onForgetServer = { scope.launch { container.authManager.forgetServer(it) } },
                )
            }
        }
    }
}

/** Composer prefill + file handoff from a share, consumed on the next chat open. */
private var sharePrefill: String? = null
private var shareFileUploads: List<Pair<ByteArray, String>> = emptyList()

/** Best-effort human filename for a shared content URI (falls back to a guess). */
private fun resolveDisplayName(context: android.content.Context, uri: android.net.Uri): String {
    if (uri.scheme == "content") {
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && cursor.moveToFirst()) {
                    cursor.getString(nameIndex)?.takeIf { it.isNotBlank() }?.let { return it }
                }
            }
        }
    }
    return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "shared-file"
}
