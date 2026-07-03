package com.hermex.app.ui.navigation

/** Normalized startup intent consumed by Compose navigation. */
sealed interface HermesLaunchRequest {
    data class NewChat(
        val initialDraft: String = "",
        val autoStartVoice: Boolean = false,
        val profileName: String? = null
    ) : HermesLaunchRequest

    data class OpenSession(val sessionId: String) : HermesLaunchRequest

    companion object {
        private const val ACTION_SEND = "android.intent.action.SEND"
        private const val ACTION_VIEW = "android.intent.action.VIEW"

        fun fromParts(action: String?, dataUri: String?, mimeType: String?, extraText: String?): HermesLaunchRequest? {
            if (action == ACTION_SEND) {
                val draft = extraText?.trim().orEmpty()
                if (draft.isNotEmpty()) return NewChat(initialDraft = draft)
            }

            if (action == ACTION_VIEW && !dataUri.isNullOrBlank()) {
                HermesDeepLink.sessionId(dataUri)?.let { return OpenSession(it) }
                if (HermesDeepLink.isNewChatVoiceUrl(dataUri)) return NewChat(autoStartVoice = true)
                if (HermesDeepLink.isNewChatInProfileUrl(dataUri)) {
                    return NewChat(profileName = HermesDeepLink.profileNameFromNewChatInProfile(dataUri))
                }
                if (HermesDeepLink.isNewChatUrl(dataUri)) return NewChat()
            }

            return null
        }
    }
}
