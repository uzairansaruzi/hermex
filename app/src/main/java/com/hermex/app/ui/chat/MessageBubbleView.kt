package com.hermex.app.ui.chat

import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.hermex.app.data.model.ChatMessage
import io.noties.markwon.Markwon
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.inlineparser.MarkwonInlineParserPlugin
import io.noties.markwon.syntax.Prism4jThemeDefault
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import io.noties.prism4j.annotations.PrismBundle

@PrismBundle(
    include = [
        "kotlin", "java", "swift", "python", "javascript", "json", "yaml",
        "markup", "sql", "go", "c", "cpp", "csharp", "css", "markdown"
    ],
    grammarLocatorClassName = ".ChatGrammarLocator"
)
private object MarkdownSetup

@Composable
private fun rememberMarkwon(): Markwon {
    val context = LocalContext.current
    return remember(context) {
        Markwon.builder(context)
            .usePlugin(MarkwonInlineParserPlugin.create())
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(
                SyntaxHighlightPlugin.create(
                    Prism4j(ChatGrammarLocator()),
                    Prism4jThemeDefault.create(0)
                )
            )
            .build()
    }
}

@Composable
fun MessageBubbleView(
    message: ChatMessage,
    isStreaming: Boolean = false,
    modifier: Modifier = Modifier
) {
    when (message.role) {
        "user" -> UserMessageBubble(message, modifier)
        "assistant" -> AssistantMessageBubble(message, isStreaming, modifier)
        else -> AssistantMessageBubble(message, isStreaming, modifier)
    }
}

@Composable
private fun UserMessageBubble(
    message: ChatMessage,
    modifier: Modifier = Modifier
) {
    val content = message.content ?: return
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.End
    ) {
        Surface(
            color = MaterialTheme.colorScheme.secondaryContainer,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.padding(start = 64.dp, top = 2.dp, bottom = 2.dp)
        ) {
            Text(
                text = content,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)
            )
        }
    }
}

@Composable
private fun AssistantMessageBubble(
    message: ChatMessage,
    isStreaming: Boolean,
    modifier: Modifier = Modifier
) {
    val content = message.content?.takeIf { it.isNotBlank() } ?: " "
    val markwon = rememberMarkwon()
    val textColor = LocalContentColor.current
    val markdown = remember(content, markwon) {
        val node = markwon.parse(content)
        markwon.render(node)
    }

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Start
    ) {
        AndroidView(
            factory = { ctx ->
                TextView(ctx).apply {
                    setTextColor(textColor.toArgb())
                    textSize = 16f
                    setLineSpacing(0f, 1.2f)
                }
            },
            update = { textView ->
                textView.setTextColor(textColor.toArgb())
                markwon.setParsedMarkdown(textView, markdown)
            },
            modifier = Modifier
                .padding(end = 48.dp, top = 2.dp, bottom = 2.dp)
        )
    }
}
