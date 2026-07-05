package com.hermexapp.android.ui.markdown

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hermexapp.android.ui.theme.LocalHermexPalette

/**
 * A small, dependency-free Markdown renderer built for *incrementally growing*
 * text (the plan's flagged risk — swift-markdown-ui has no Compose analog).
 * The block parser tolerates an unterminated fence or half-written table, so a
 * response mid-stream never throws or flickers: an open ``` fence just renders
 * what it has so far as a code block. Supports headings, bold/italic/inline
 * code/links inline, fenced code blocks, bullet/ordered lists, blockquotes, and
 * pipe tables — the shapes hermes responses actually use.
 */
@Composable
fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    baseStyle: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyLarge,
) {
    val blocks = remember(text) { parseBlocks(text) }
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block -> BlockView(block, baseStyle) }
    }
}

@Composable
private fun BlockView(block: MdBlock, baseStyle: androidx.compose.ui.text.TextStyle) {
    val palette = LocalHermexPalette.current
    when (block) {
        is MdBlock.Heading -> Text(
            inlineAnnotated(block.text, palette.accent),
            style = when (block.level) {
                1 -> MaterialTheme.typography.headlineSmall
                2 -> MaterialTheme.typography.titleLarge
                else -> MaterialTheme.typography.titleMedium
            },
            fontWeight = FontWeight.Bold,
        )

        is MdBlock.Paragraph -> Text(inlineAnnotated(block.text, palette.accent), style = baseStyle)

        is MdBlock.Code -> Surface(
            color = palette.card,
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                block.language?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = palette.textSecondary)
                }
                val codeColors = CodeColors(
                    keyword = palette.accent,
                    string = palette.success,
                    comment = palette.textSecondary,
                    number = palette.warning,
                )
                val highlighted = remember(block.code, block.language, palette.accent) {
                    highlightCode(block.code, block.language, codeColors)
                }
                Column(modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    Text(
                        highlighted,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        softWrap = false,
                    )
                }
            }
        }

        is MdBlock.BulletList -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            block.items.forEach { item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("•", style = baseStyle, color = palette.textSecondary)
                    Text(inlineAnnotated(item, palette.accent), style = baseStyle)
                }
            }
        }

        is MdBlock.OrderedList -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            block.items.forEachIndexed { index, item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${block.start + index}.", style = baseStyle, color = palette.textSecondary)
                    Text(inlineAnnotated(item, palette.accent), style = baseStyle)
                }
            }
        }

        is MdBlock.Quote -> Surface(
            color = palette.card,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                inlineAnnotated(block.text, palette.accent),
                modifier = Modifier.padding(12.dp),
                style = baseStyle,
                color = palette.textSecondary,
            )
        }

        is MdBlock.Table -> TableView(block, baseStyle)
    }
}

@Composable
private fun TableView(table: MdBlock.Table, baseStyle: androidx.compose.ui.text.TextStyle) {
    val palette = LocalHermexPalette.current
    val columnWidth = 160.dp
    Surface(color = palette.card, shape = RoundedCornerShape(10.dp)) {
        Column(modifier = Modifier.horizontalScroll(rememberScrollState()).padding(8.dp)) {
            Row {
                table.header.forEach { cell ->
                    Text(
                        inlineAnnotated(cell, palette.accent),
                        modifier = Modifier.width(columnWidth).padding(6.dp),
                        style = baseStyle,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            table.rows.forEach { row ->
                Row {
                    row.forEach { cell ->
                        Text(
                            inlineAnnotated(cell, palette.accent),
                            modifier = Modifier.width(columnWidth).padding(6.dp),
                            style = baseStyle,
                        )
                    }
                }
            }
        }
    }
}

// ── Inline formatting: **bold**, *italic*/_italic_, `code`, [text](url) ──

private fun inlineAnnotated(source: String, linkColor: androidx.compose.ui.graphics.Color): AnnotatedString =
    buildAnnotatedString {
        var i = 0
        while (i < source.length) {
            val c = source[i]
            when {
                c == '*' && i + 1 < source.length && source[i + 1] == '*' -> {
                    val end = source.indexOf("**", i + 2)
                    if (end > 0) {
                        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(source.substring(i + 2, end)) }
                        i = end + 2
                    } else { append(c); i++ }
                }
                (c == '*' || c == '_') -> {
                    val end = source.indexOf(c, i + 1)
                    if (end > i + 1) {
                        withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(source.substring(i + 1, end)) }
                        i = end + 1
                    } else { append(c); i++ }
                }
                c == '`' -> {
                    val end = source.indexOf('`', i + 1)
                    if (end > 0) {
                        withStyle(SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 14.sp)) {
                            append(source.substring(i + 1, end))
                        }
                        i = end + 1
                    } else { append(c); i++ }
                }
                c == '[' -> {
                    val close = source.indexOf(']', i)
                    val open = if (close > 0) source.getOrNull(close + 1) else null
                    if (close > 0 && open == '(') {
                        val paren = source.indexOf(')', close)
                        if (paren > 0) {
                            withStyle(SpanStyle(color = linkColor)) { append(source.substring(i + 1, close)) }
                            i = paren + 1
                        } else { append(c); i++ }
                    } else { append(c); i++ }
                }
                else -> { append(c); i++ }
            }
        }
    }
