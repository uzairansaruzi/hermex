package com.hermex.app.ui.navigation

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.auth.AuthState
import com.hermex.app.ui.onboarding.OnboardingScreen
import com.hermex.app.ui.sessionlist.SessionListScreen
import com.hermex.app.ui.chat.ChatScreen
import com.hermex.app.ui.tasks.TasksScreen
import com.hermex.app.ui.skills.SkillsScreen
import com.hermex.app.ui.memory.MemoryScreen
import com.hermex.app.ui.insights.InsightsScreen
import com.hermex.app.ui.settings.SettingsScreen
import com.hermex.app.ui.workspace.FileBrowserScreen

object Routes {
    const val ONBOARDING = "onboarding"
    const val SESSIONS = "sessions"
    const val CHAT = "chat/{sessionId}?draft={draft}&voice={voice}"
    const val TASKS = "tasks"
    const val SKILLS = "skills"
    const val MEMORY = "memory"
    const val INSIGHTS = "insights"
    const val SETTINGS = "settings"
    const val FILE_BROWSER = "file_browser/{sessionId}"
    fun chat(sessionId: String, initialDraft: String = "", autoStartVoice: Boolean = false): String {
        return "chat/${Uri.encode(sessionId)}?draft=${Uri.encode(initialDraft)}&voice=$autoStartVoice"
    }
    // C2 fix: URI-encode sessionId to prevent route-breaking chars (/, ?, #).
    fun fileBrowser(sessionId: String) = "file_browser/${Uri.encode(sessionId)}"
}

@Composable
fun HermexNavHost(
    authManager: AuthManager,
    launchRequestViewModel: LaunchRequestViewModel = hiltViewModel(),
    navController: NavHostController = rememberNavController()
) {
    // authState is a StateFlow — collectAsState() reads the current value
    // synchronously (no dummy initial needed), so startDestination is correct
    // on the very first frame even for logged-in users.
    val authState by authManager.authState.collectAsState()
    val pendingRequest by launchRequestViewModel.pendingRequest.collectAsState()

    // C4 fix: compute startDestination once and freeze it. Live authState
    // changes are handled by the LaunchedEffect below, not by rebuilding
    // the NavGraph (which would reset the back stack mid-session).
    val startDestination by rememberSaveable {
        mutableStateOf(
            when (authState) {
                AuthState.LOGGED_IN -> Routes.SESSIONS
                else -> Routes.ONBOARDING
            }
        )
    }

    // B5 fix: redirect to onboarding when auth is lost mid-session, and
    // redirect to sessions when logged-in state is reached while stuck on
    // onboarding (safety net for any startDestination freeze edge case).
    LaunchedEffect(authState) {
        val currentRoute = navController.currentBackStackEntry?.destination?.route
        when {
            authState == AuthState.LOGGED_IN && currentRoute == Routes.ONBOARDING -> {
                navController.navigate(Routes.SESSIONS) {
                    popUpTo(Routes.ONBOARDING) { inclusive = true }
                }
            }
            (authState == AuthState.LOGGED_OUT || authState == AuthState.UNCONFIGURED)
                && currentRoute != null && currentRoute != Routes.ONBOARDING -> {
                navController.navigate(Routes.ONBOARDING) {
                    popUpTo(0) { inclusive = true }
                }
            }
        }
    }

    // Dispatch pending launch requests when authenticated.
    // The ViewModel clears pendingRequest synchronously in dispatch() and
    // emits a LaunchNavEvent asynchronously — no navController capture.
    LaunchedEffect(pendingRequest, authState) {
        val request = pendingRequest ?: return@LaunchedEffect
        if (authState != AuthState.LOGGED_IN) return@LaunchedEffect
        launchRequestViewModel.dispatch(request)
    }

    // Collect one-shot navigation events from the ViewModel.
    // Channel.BUFFERED ensures events survive configuration changes.
    LaunchedEffect(Unit) {
        launchRequestViewModel.navEvents.collect { event ->
            when (event) {
                is LaunchNavEvent.OpenChat -> {
                    navController.navigate(
                        Routes.chat(event.sessionId, event.initialDraft, event.autoStartVoice)
                    ) {
                        popUpTo(Routes.SESSIONS) { inclusive = false }
                    }
                }
            }
        }
    }

    NavHost(
        navController = navController,
        startDestination = startDestination
    ) {
        composable(Routes.ONBOARDING) {
            OnboardingScreen(
                onConnected = {
                    navController.navigate(Routes.SESSIONS) {
                        popUpTo(Routes.ONBOARDING) { inclusive = true }
                    }
                }
            )
        }

        composable(Routes.SESSIONS) {
            SessionListScreen(
                onSessionClick = { sessionId ->
                    navController.navigate(Routes.chat(sessionId))
                },
                onNewChatCreated = { sessionId, initialDraft, autoStartVoice ->
                    navController.navigate(Routes.chat(sessionId, initialDraft, autoStartVoice))
                },
                onReconnectClick = {
                    authManager.markLoggedOut()
                    navController.navigate(Routes.ONBOARDING) {
                        popUpTo(0) { inclusive = true }
                    }
                },
                onSettingsClick = {
                    navController.navigate(Routes.SETTINGS)
                },
                onTasksClick = {
                    navController.navigate(Routes.TASKS)
                },
                onSkillsClick = {
                    navController.navigate(Routes.SKILLS)
                },
                onMemoryClick = {
                    navController.navigate(Routes.MEMORY)
                },
                onInsightsClick = {
                    navController.navigate(Routes.INSIGHTS)
                }
            )
        }

        composable(
            route = Routes.CHAT,
            arguments = listOf(
                navArgument("sessionId") { type = NavType.StringType },
                navArgument("draft") { type = NavType.StringType; defaultValue = "" },
                navArgument("voice") { type = NavType.BoolType; defaultValue = false }
            )
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString("sessionId") ?: return@composable
            val initialDraft = backStackEntry.arguments?.getString("draft").orEmpty()
            val autoStartVoice = backStackEntry.arguments?.getBoolean("voice") ?: false
            ChatScreen(
                sessionId = sessionId,
                initialDraft = initialDraft,
                autoStartVoiceInput = autoStartVoice,
                onBack = { navController.popBackStack() },
                onNavigateToSession = { sid -> navController.navigate(Routes.chat(sid)) },
                onNewSession = { navController.navigate(Routes.SESSIONS) },
                onNavigateToFileBrowser = { sid ->
                    navController.navigate(Routes.fileBrowser(sid))
                }
            )
        }

        composable(Routes.TASKS) {
            TasksScreen(onBack = { navController.popBackStack() })
        }

        composable(Routes.SKILLS) {
            SkillsScreen(onBack = { navController.popBackStack() })
        }

        composable(Routes.MEMORY) {
            MemoryScreen(onBack = { navController.popBackStack() })
        }

        composable(Routes.INSIGHTS) {
            InsightsScreen(onBack = { navController.popBackStack() })
        }

        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() },
                onSignOut = {
                    authManager.clearAuth()
                    navController.navigate(Routes.ONBOARDING) {
                        popUpTo(0) { inclusive = true }
                    }
                }
            )
        }

        composable(
            route = Routes.FILE_BROWSER,
            arguments = listOf(navArgument("sessionId") { type = NavType.StringType })
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString("sessionId") ?: return@composable
            FileBrowserScreen(
                sessionId = sessionId,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
