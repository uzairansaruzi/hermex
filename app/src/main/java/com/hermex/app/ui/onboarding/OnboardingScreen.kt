package com.hermex.app.ui.onboarding

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.hermex.app.data.auth.AuthManager
import com.hermex.app.data.model.LoginResponse
import com.hermex.app.data.network.ApiClient
import com.hermex.app.data.network.ApiException
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

sealed interface ConnectionStatus {
    data object Idle : ConnectionStatus
    data object Testing : ConnectionStatus
    data object Connecting : ConnectionStatus
    data class Success(val message: String) : ConnectionStatus
    data class Error(val message: String) : ConnectionStatus
}

@HiltViewModel
class OnboardingViewModel @Inject constructor(
    private val apiClient: ApiClient,
    private val authManager: AuthManager
) : ViewModel() {

    private val _serverUrl = MutableStateFlow(authManager.serverUrl.orEmpty())
    val serverUrl: StateFlow<String> = _serverUrl.asStateFlow()

    private val _password = MutableStateFlow(authManager.getPassword().orEmpty())
    val password: StateFlow<String> = _password.asStateFlow()

    private val _status = MutableStateFlow<ConnectionStatus>(ConnectionStatus.Idle)
    val status: StateFlow<ConnectionStatus> = _status.asStateFlow()

    fun onServerUrlChange(value: String) {
        _serverUrl.value = value
    }

    fun onPasswordChange(value: String) {
        _password.value = value
    }

    fun testConnection() {
        val url = _serverUrl.value.trim()
        if (url.isEmpty()) {
            _status.value = ConnectionStatus.Error("Please enter a server URL.")
            return
        }

        _status.value = ConnectionStatus.Testing
        viewModelScope.launch {
            runWithHttpsFallback(url) { candidate ->
                apiClient.configure(candidate)
                val response = apiClient.health()
                _serverUrl.value = apiClient.baseUrl
                _status.value = ConnectionStatus.Success(
                    response.status?.let { "Connected. Server status: $it." }
                        ?: "Connection successful."
                )
            }
        }
    }

    fun connect(onConnected: () -> Unit) {
        val url = _serverUrl.value.trim()
        if (url.isEmpty()) {
            _status.value = ConnectionStatus.Error("Please enter a server URL.")
            return
        }

        _status.value = ConnectionStatus.Connecting
        viewModelScope.launch {
            runWithHttpsFallback(url) { candidate ->
                connectOnce(candidate, onConnected)
            }
        }
    }

    private suspend fun connectOnce(url: String, onConnected: () -> Unit) {
        apiClient.configure(url)
        authManager.saveServer(apiClient.baseUrl)
        _serverUrl.value = apiClient.baseUrl

        val password = _password.value
        if (password.isNotBlank()) {
            authManager.savePassword(password)
            val loginResponse: LoginResponse = apiClient.login(password)
            if (loginResponse.ok != true) {
                val error = loginResponse.error ?: "Login failed."
                _status.value = ConnectionStatus.Error(error)
                return
            }
        }

        authManager.markLoggedIn()
        _status.value = ConnectionStatus.Success("Connected successfully.")
        onConnected()
    }

    private suspend fun runWithHttpsFallback(
        originalUrl: String,
        block: suspend (String) -> Unit
    ) {
        try {
            block(originalUrl)
        } catch (error: Exception) {
            val fallbackUrl = httpFallbackUrl(originalUrl)
            if (fallbackUrl != null && error.looksLikePlainHttpBehindHttps()) {
                try {
                    block(fallbackUrl)
                    return
                } catch (fallbackError: Exception) {
                    handleConnectionError(fallbackError)
                    return
                }
            }
            handleConnectionError(error)
        }
    }

    private fun httpFallbackUrl(url: String): String? {
        val trimmed = url.trim()
        return if (trimmed.startsWith("https://", ignoreCase = true)) {
            "http://" + trimmed.substringAfter("://")
        } else {
            null
        }
    }

    private fun Throwable.looksLikePlainHttpBehindHttps(): Boolean {
        val parts = mutableListOf<String>()
        var current: Throwable? = this
        while (current != null) {
            parts += current::class.qualifiedName.orEmpty()
            parts += current.message.orEmpty()
            parts += current.localizedMessage.orEmpty()
            current = current.cause
        }
        val text = parts.joinToString(" ")
        return text.contains("Unable to parse TLS packet header", ignoreCase = true) ||
            text.contains("not an SSL/TLS record", ignoreCase = true) ||
            text.contains("CLEARTEXT", ignoreCase = true)
    }

    private fun handleConnectionError(error: Exception) {
        _status.value = when (error) {
            is ApiException.Unauthorized -> ConnectionStatus.Error("Unauthorized. Check your server URL or password.")
            is ApiException.Http -> ConnectionStatus.Error("Server error ${error.code}: ${error.body}")
            is ApiException.Network -> ConnectionStatus.Error("Network error: ${error.localizedMessage ?: "Unable to reach server."}")
            is ApiException.Decoding -> ConnectionStatus.Error("Unexpected response from server.")
            else -> ConnectionStatus.Error(error.localizedMessage ?: "Connection failed.")
        }
    }
}

@Composable
fun OnboardingScreen(
    onConnected: () -> Unit,
    viewModel: OnboardingViewModel = hiltViewModel()
) {
    val serverUrl by viewModel.serverUrl.collectAsStateWithLifecycle()
    val password by viewModel.password.collectAsStateWithLifecycle()
    val status by viewModel.status.collectAsStateWithLifecycle()

    val snackbarHostState = remember { SnackbarHostState() }
    val focusManager = LocalFocusManager.current
    val passwordFocusRequester = remember { FocusRequester() }
    var passwordVisible by remember { mutableStateOf(false) }

    LaunchedEffect(status) {
        if (status is ConnectionStatus.Error) {
            snackbarHostState.showSnackbar((status as ConnectionStatus.Error).message)
        }
    }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(innerPadding)
                .padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(24.dp))

            WelcomeHeader()

            Spacer(modifier = Modifier.height(8.dp))

            ServerForm(
                serverUrl = serverUrl,
                onServerUrlChange = viewModel::onServerUrlChange,
                password = password,
                onPasswordChange = viewModel::onPasswordChange,
                passwordVisible = passwordVisible,
                onTogglePasswordVisibility = { passwordVisible = !passwordVisible },
                onNextFromServerUrl = { passwordFocusRequester.requestFocus() },
                passwordFocusRequester = passwordFocusRequester,
                onSubmit = { viewModel.connect(onConnected) }
            )

            StatusIndicator(status = status)

            ActionButtons(
                status = status,
                onTestConnection = {
                    focusManager.clearFocus()
                    viewModel.testConnection()
                },
                onConnect = {
                    focusManager.clearFocus()
                    viewModel.connect(onConnected)
                }
            )

            Spacer(modifier = Modifier.height(24.dp))
        }
    }
}

@Composable
private fun WelcomeHeader(
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(
            imageVector = Icons.Default.Link,
            contentDescription = null,
            modifier = Modifier.size(80.dp),
            tint = MaterialTheme.colorScheme.primary
        )

        Text(
            text = "Welcome to Hermex",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.onBackground,
            textAlign = TextAlign.Center
        )

        Text(
            text = "Control your self-hosted Hermes agent from your Android device.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun ServerForm(
    serverUrl: String,
    onServerUrlChange: (String) -> Unit,
    password: String,
    onPasswordChange: (String) -> Unit,
    passwordVisible: Boolean,
    onTogglePasswordVisibility: () -> Unit,
    onNextFromServerUrl: () -> Unit,
    passwordFocusRequester: FocusRequester,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        OutlinedTextField(
            value = serverUrl,
            onValueChange = onServerUrlChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Server URL") },
            placeholder = { Text("https://hermes.yourdomain.com") },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Link,
                    contentDescription = null
                )
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Next
            ),
            keyboardActions = KeyboardActions(
                onNext = { onNextFromServerUrl() }
            )
        )

        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChange,
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(passwordFocusRequester),
            label = { Text("Password (optional)") },
            placeholder = { Text("Server password") },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Lock,
                    contentDescription = null
                )
            },
            trailingIcon = {
                IconButton(onClick = onTogglePasswordVisibility) {
                    Icon(
                        imageVector = if (passwordVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                        contentDescription = if (passwordVisible) "Hide password" else "Show password"
                    )
                }
            },
            singleLine = true,
            visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Done
            ),
            keyboardActions = KeyboardActions(
                onDone = { onSubmit() }
            )
        )
    }
}

@Composable
private fun StatusIndicator(
    status: ConnectionStatus,
    modifier: Modifier = Modifier
) {
    when (status) {
        is ConnectionStatus.Idle -> Unit
        is ConnectionStatus.Testing,
        is ConnectionStatus.Connecting -> {
            Row(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(
                    12.dp,
                    Alignment.CenterHorizontally
                ),
                verticalAlignment = Alignment.CenterVertically
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp
                )
                Text(
                    text = if (status is ConnectionStatus.Testing) "Testing connection…" else "Connecting…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        is ConnectionStatus.Success -> {
            Row(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(
                    8.dp,
                    Alignment.CenterHorizontally
                ),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = status.message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }

        is ConnectionStatus.Error -> {
            Row(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(
                    8.dp,
                    Alignment.CenterHorizontally
                ),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Error,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error
                )
                Text(
                    text = status.message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}

@Composable
private fun ActionButtons(
    status: ConnectionStatus,
    onTestConnection: () -> Unit,
    onConnect: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isBusy = status is ConnectionStatus.Testing || status is ConnectionStatus.Connecting

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        OutlinedButton(
            onClick = onTestConnection,
            modifier = Modifier.fillMaxWidth(),
            enabled = !isBusy
        ) {
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                modifier = Modifier.padding(end = 8.dp)
            )
            Text("Test Connection")
        }

        Button(
            onClick = onConnect,
            modifier = Modifier.fillMaxWidth(),
            enabled = !isBusy
        ) {
            Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                modifier = Modifier.padding(end = 8.dp)
            )
            Text("Connect")
        }
    }
}
