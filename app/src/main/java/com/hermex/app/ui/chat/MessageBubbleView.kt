package com.hermex.app.ui.chat

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.widget.TextView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.hermex.app.data.model.ChatMessage
import com.hermex.app.ui.theme.HermexColors
import io.noties.markwon.Markwon
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.tables.TableTheme
import io.noties.markwon.inlineparser.MarkwonInlineParserPlugin
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import io.noties.prism4j.annotations.PrismBundle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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
    val isDarkTheme = isSystemInDarkTheme()
    return remember(context, isDarkTheme) {
        val prism4j = Prism4j(ChatGrammarLocator())
        val theme = HermexPrismTheme()

        val tableTheme = TableTheme.Builder()
            .tableBorderColor(
                if (isDarkTheme) HermexColors.TableBorderDark.toArgb()
                else HermexColors.TableBorderLight.toArgb()
            )
            .tableBorderWidth(1)
            .tableCellPadding(13)
            .tableHeaderRowBackgroundColor(
                if (isDarkTheme) HermexColors.TableRowOddDark.toArgb()
                else HermexColors.TableRowOddLight.toArgb()
            )
            .tableEvenRowBackgroundColor(
                if (isDarkTheme) HermexColors.TableRowEvenDark.toArgb()
                else HermexColors.TableRowEvenLight.toArgb()
            )
            .tableOddRowBackgroundColor(
                if (isDarkTheme) HermexColors.TableRowOddDark.toArgb()
                else HermexColors.TableRowOddLight.toArgb()
            )
            .build()

        Markwon.builder(context)
            .usePlugin(MarkwonInlineParserPlugin.create())
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(TablePlugin.create(tableTheme))
            .usePlugin(
                SyntaxHighlightPlugin.create(
                    prism4j,
                    theme
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
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)),
            modifier = Modifier.padding(start = 32.dp, top = 2.dp, bottom = 2.dp)
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
    val segments = remember(content) { parseCodeBlocks(content) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(end = 48.dp, top = 2.dp, bottom = 2.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        for (segment in segments) {
            when (segment) {
                is ContentSegment.Prose -> ProseBlock(segment.text)
                is ContentSegment.Code -> CodeBlockCard(
                    language = segment.language,
                    code = segment.code
                )
            }
        }
    }
}

@Composable
private fun ProseBlock(text: String) {
    val markwon = rememberMarkwon()
    val textColor = LocalContentColor.current
    val markdown = remember(text, markwon) {
        val node = markwon.parse(text)
        markwon.render(node)
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(textColor.toArgb())
                textSize = 17f
                setLineSpacing(0f, 1.25f)
            }
        },
        update = { textView ->
            textView.setTextColor(textColor.toArgb())
            markwon.setParsedMarkdown(textView, markdown)
        },
        modifier = Modifier.fillMaxWidth()
    )
}

@Composable
private fun CodeBlockCard(language: String?, code: String) {
    val isDarkTheme = isSystemInDarkTheme()
    val bgColor = if (isDarkTheme) HermexColors.CodeBlockBackgroundDark
    else HermexColors.CodeBlockBackgroundLight
    val borderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)
    val clipboardManager = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var showCopied by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(24.dp),
        color = bgColor,
        border = BorderStroke(1.dp, borderColor)
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Header row: language label + copy button
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 4.dp, top = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = language?.replaceFirstChar { it.uppercase() } ?: "Code",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                IconButton(
                    onClick = {
                        clipboardManager.setText(AnnotatedString(code))
                        showCopied = true
                        scope.launch {
                            delay(2000)
                            showCopied = false
                        }
                    },
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        imageVector = if (showCopied) Icons.Default.Check else Icons.Default.ContentCopy,
                        contentDescription = if (showCopied) "Copied" else "Copy code",
                        tint = if (showCopied) HermexColors.SuccessDark
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            // Syntax-highlighted code (horizontally scrollable)
            val prism4j = remember { Prism4j(ChatGrammarLocator()) }
            val theme = remember { HermexPrismTheme() }
            val highlighted = remember(code, language) {
                highlightCode(prism4j, theme, language, code)
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(start = 16.dp, end = 16.dp, bottom = 14.dp, top = 4.dp)
            ) {
                val plainColor = if (isDarkTheme) HermexColors.SyntaxPlainDark.toArgb()
                    else HermexColors.SyntaxPlainLight.toArgb()
                AndroidView(
                    factory = { ctx ->
                        TextView(ctx).apply {
                            typeface = Typeface.MONOSPACE
                            textSize = 13f
                            setLineSpacing(0f, 1.3f)
                            setTextColor(plainColor)
                        }
                    },
                    update = { textView ->
                        textView.text = highlighted
                    }
                )
            }
        }
    }
}

// ─── Helpers ───────────────────────────────────────��─────────────────────────

private fun highlightCode(
    prism4j: Prism4j,
    theme: HermexPrismTheme,
    language: String?,
    code: String
): CharSequence {
    val lang = language?.lowercase()
    val grammar = lang?.let { prism4j.grammar(it) }
    if (grammar == null) return code

    val nodes = prism4j.tokenize(code, grammar)
    val builder = SpannableStringBuilder()
    appendNodes(nodes, builder, theme, lang)
    return builder
}

private fun appendNodes(
    nodes: List<Prism4j.Node>,
    builder: SpannableStringBuilder,
    theme: HermexPrismTheme,
    language: String
) {
    for (node in nodes) {
        val start = builder.length
        when (node) {
            is Prism4j.Text -> builder.append(node.literal())
            is Prism4j.Syntax -> {
                appendNodes(node.children(), builder, theme, language)
                theme.apply(language, node, builder, start, builder.length)
            }
        }
    }
}

/** Splits markdown content into prose and fenced code block segments. */
private fun parseCodeBlocks(content: String): List<ContentSegment> {
    val segments = mutableListOf<ContentSegment>()
    val lines = content.lines()
    var i = 0
    val proseBuilder = StringBuilder()

    while (i < lines.size) {
        val line = lines[i]
        val fenceMatch = FENCE_REGEX.matchEntire(line)

        if (fenceMatch != null) {
            // Flush prose
            if (proseBuilder.isNotEmpty()) {
                segments.add(ContentSegment.Prose(proseBuilder.toString().removeSuffix("\n")))
                proseBuilder.clear()
            }

            val fence = fenceMatch.groupValues[1]
            val lang = fenceMatch.groupValues[2].takeIf { it.isNotBlank() }
            val codeBuilder = StringBuilder()
            i++

            // Read until closing fence
            while (i < lines.size) {
                val codeLine = lines[i]
                if (codeLine.trimEnd().startsWith(fence) && codeLine.trim().length <= fence.length + 1) {
                    break
                }
                if (codeBuilder.isNotEmpty()) codeBuilder.append('\n')
                codeBuilder.append(codeLine)
                i++
            }

            segments.add(ContentSegment.Code(lang, codeBuilder.toString()))
            i++ // skip closing fence
        } else {
            proseBuilder.append(line).append('\n')
            i++
        }
    }

    // Flush remaining prose
    if (proseBuilder.isNotEmpty()) {
        segments.add(ContentSegment.Prose(proseBuilder.toString().removeSuffix("\n")))
    }

    return segments
}

private val FENCE_REGEX = Regex("^(```+)\\s*(\\S*)\\s*$")

private sealed class ContentSegment {
    data class Prose(val text: String) : ContentSegment()
    data class Code(val language: String?, val code: String) : ContentSegment()
}

