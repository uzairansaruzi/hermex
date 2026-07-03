package com.hermex.app.ui.navigation

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
import com.hermex.app.ui.git.GitWorkspaceScreen

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
    const val GIT_WORKSPACE = "git/{sessionId}"

    fun chat(sessionId: String, initialDraft: String = "", autoStartVoice: Boolean = false): String {
        return "chat/${Uri.encode(sessionId)}?draft=${Uri.encode(initialDraft)}&voice=$autoStartVoice"
    }
    fun fileBrowser(sessionId: String) = "file_browser/$sessionId"
    fun git(sessionId: String) = "git/$sessionId"
}

@Composable
fun HermexNavHost(
    authManager: AuthManager,
    pendingLaunchRequest: HermesLaunchRequest? = null,
    onLaunchRequestConsumed: () -> Unit = {},
    navController: NavHostController = rememberNavController()
) {
    val authState by authManager.authState.collectAsState(initial = AuthState.UNCONFIGURED)

    val startDestination = when (authState) {
        AuthState.UNCONFIGURED -> Routes.ONBOARDING
        AuthState.LOGGED_OUT -> Routes.ONBOARDING
        AuthState.LOGGED_IN -> Routes.SESSIONS
    }

    // Handle launch requests (deep links, notification taps, SEND intents) at the
    // nav-host level so they work regardless of which screen is currently visible.
    // Without this, an intent arriving while on chat/settings/etc. is never consumed
    // because the SessionListScreen LaunchedEffect isn't in the composition.
    LaunchedEffect(pendingLaunchRequest) {
        val request = pendingLaunchRequest ?: return@LaunchedEffect
        when (request) {
            is HermesLaunchRequest.OpenSession -> {
                navController.navigate(Routes.chat(request.sessionId)) {
                    popUpTo(Routes.SESSIONS) { inclusive = false }
                }
            }
            is HermesLaunchRequest.NewChat -> {
                // Navigate to sessions first so the SessionListScreen can create
                // the session and navigate to it.  This is handled below in
                // SessionListScreen's own LaunchedEffect for backward compat.
                val currentRoute = navController.currentBackStackEntry?.destination?.route
                if (currentRoute != Routes.SESSIONS) {
                    navController.navigate(Routes.SESSIONS) {
                        popUpTo(Routes.SESSIONS) { inclusive = true }
                    }
                }
                // Don't consume — let SessionListScreen handle creation + nav.
                return@LaunchedEffect
            }
        }
        onLaunchRequestConsumed()
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
                pendingLaunchRequest = pendingLaunchRequest,
                onLaunchRequestConsumed = onLaunchRequestConsumed,
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
                },
                onNavigateToGit = { sid ->
                    navController.navigate(Routes.git(sid))
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

        composable(
            route = Routes.GIT_WORKSPACE,
            arguments = listOf(navArgument("sessionId") { type = NavType.StringType })
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString("sessionId") ?: return@composable
            GitWorkspaceScreen(
                sessionId = sessionId,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
