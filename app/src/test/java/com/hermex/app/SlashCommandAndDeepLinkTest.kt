package com.hermex.app

import com.hermex.app.ui.chat.slash.ParsedSlashQuery
import com.hermex.app.ui.chat.slash.ServerSideAction
import com.hermex.app.ui.chat.slash.SlashCommandCatalog
import com.hermex.app.ui.chat.slash.SlashCommandHandler
import com.hermex.app.ui.navigation.HermesDeepLink
import com.hermex.app.ui.navigation.HermesLaunchRequest
import org.junit.Assert.*
import org.junit.Test

class SlashCommandAndDeepLinkTest {
    @Test
    fun matchingEmptyQueryReturnsAllCommands() {
        assertEquals(SlashCommandCatalog.allCommands.size, SlashCommandCatalog.matching("").size)
    }

    @Test
    fun matchingIsCaseInsensitiveAndSearchesDescriptions() {
        assertTrue(SlashCommandCatalog.matching("MODEL").any { it.name == "model" })
        assertTrue(SlashCommandCatalog.matching("clear").any { it.name == "clear" })
    }

    @Test
    fun mobileSafeAdvancedCommandsMatchIosCatalog() {
        assertEquals(SlashCommandHandler.ServerSide(ServerSideAction.Branch), SlashCommandCatalog.command("branch")?.handler)
        assertEquals(SlashCommandHandler.ServerSide(ServerSideAction.Branch), SlashCommandCatalog.command("fork")?.handler)
        assertTrue(SlashCommandCatalog.command("branch")?.noEcho == true)
        assertEquals("name", SlashCommandCatalog.command("fork")?.argHint)

        assertEquals(SlashCommandHandler.ServerSide(ServerSideAction.Undo), SlashCommandCatalog.command("undo")?.handler)
        assertEquals(SlashCommandHandler.ServerSide(ServerSideAction.Retry), SlashCommandCatalog.command("retry")?.handler)
        assertEquals(SlashCommandHandler.ServerSide(ServerSideAction.Compress), SlashCommandCatalog.command("compact")?.handler)
        assertEquals("focus topic", SlashCommandCatalog.command("compact")?.argHint)
    }

    @Test
    fun parsedSlashQueryExtractsCommandAndArguments() {
        val parsed = ParsedSlashQuery("/model   gpt-5.5")
        assertEquals("model", parsed.commandName)
        assertEquals("gpt-5.5", parsed.argQuery)
        assertTrue(parsed.isSubArgMode)
    }

    @Test
    fun parsedSlashQueryWithoutSpaceIsNotSubArgMode() {
        val parsed = ParsedSlashQuery("/model")
        assertEquals("model", parsed.commandName)
        assertEquals("", parsed.argQuery)
        assertFalse(parsed.isSubArgMode)
    }

    @Test
    fun deepLinkHostsDoNotAlias() {
        val plain = "hermes-agent://new-chat"
        val voice = "hermes-agent://new-chat-voice"
        val profile = "hermes-agent://new-chat-profile?profile=Phoenix%20Docs"

        assertTrue(HermesDeepLink.isNewChatUrl(plain))
        assertFalse(HermesDeepLink.isNewChatVoiceUrl(plain))

        assertTrue(HermesDeepLink.isNewChatVoiceUrl(voice))
        assertFalse(HermesDeepLink.isNewChatUrl(voice))

        assertTrue(HermesDeepLink.isNewChatInProfileUrl(profile))
        assertEquals("Phoenix Docs", HermesDeepLink.profileNameFromNewChatInProfile(profile))
    }

    @Test
    fun sessionDeepLinkExtractsQueryOrPathSessionId() {
        assertEquals("abc123", HermesDeepLink.sessionId("hermes-agent://session?id=abc123"))
        assertEquals("def456", HermesDeepLink.sessionId("hermes-agent://session/def456"))
        assertNull(HermesDeepLink.sessionId("hermes-agent://new-chat"))
    }

    @Test
    fun launchRequestParsesShareTextAndDeepLinks() {
        assertEquals(
            HermesLaunchRequest.NewChat(initialDraft = "shared text"),
            HermesLaunchRequest.fromParts(action = "android.intent.action.SEND", dataUri = null, mimeType = "text/plain", extraText = "shared text")
        )
        assertEquals(
            HermesLaunchRequest.NewChat(autoStartVoice = true),
            HermesLaunchRequest.fromParts(action = "android.intent.action.VIEW", dataUri = "hermes-agent://new-chat-voice", mimeType = null, extraText = null)
        )
        assertEquals(
            HermesLaunchRequest.NewChat(profileName = "Phoenix Docs"),
            HermesLaunchRequest.fromParts(action = "android.intent.action.VIEW", dataUri = "hermes-agent://new-chat-profile?profile=Phoenix%20Docs", mimeType = null, extraText = null)
        )
        assertEquals(
            HermesLaunchRequest.OpenSession("abc123"),
            HermesLaunchRequest.fromParts(action = "android.intent.action.VIEW", dataUri = "hermes-agent://session?id=abc123", mimeType = null, extraText = null)
        )
    }
}