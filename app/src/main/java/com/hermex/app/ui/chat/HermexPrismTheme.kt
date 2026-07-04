package com.hermex.app.ui.chat

import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import androidx.annotation.ColorInt
import androidx.compose.ui.graphics.toArgb
import com.hermex.app.ui.theme.HermexColors
import io.noties.prism4j.Prism4j

/**
 * Dark syntax highlighting theme for Markwon/Prism4j that matches the iOS app's
 * code block appearance (github-dark inspired). Transparent background — the
 * Compose layer handles the code-block card surface.
 */
class HermexPrismTheme : io.noties.markwon.syntax.Prism4jTheme {

    @ColorInt
    override fun background(): Int = 0x00000000 // transparent — Compose card handles bg

    @ColorInt
    override fun textColor(): Int = HermexColors.SyntaxPlain.toArgb()

    override fun apply(
        language: String,
        node: Prism4j.Syntax,
        builder: SpannableStringBuilder,
        start: Int,
        end: Int
    ) {
        val color = colorForNode(node) ?: return
        builder.setSpan(
            ForegroundColorSpan(color),
            start,
            end,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
        )
    }

    @ColorInt
    private fun colorForNode(node: Prism4j.Syntax): Int? {
        return when (node.type()) {
            "keyword", "boolean", "operator", "builtin", "important",
            "atrule", "tag", "selector" -> KEYWORD

            "class-name", "function", "attr-name", "property" -> TYPE

            "string", "char", "regex", "url", "attr-value" -> STRING

            "number" -> NUMBER

            "comment", "prolog", "doctype", "cdata", "block-comment" -> COMMENT

            "punctuation" -> PUNCTUATION

            else -> null
        }
    }

    companion object {
        @ColorInt private val KEYWORD = HermexColors.SyntaxKeyword.toArgb()
        @ColorInt private val TYPE = HermexColors.SyntaxType.toArgb()
        @ColorInt private val STRING = HermexColors.SyntaxString.toArgb()
        @ColorInt private val NUMBER = HermexColors.SyntaxNumber.toArgb()
        @ColorInt private val COMMENT = HermexColors.SyntaxComment.toArgb()
        @ColorInt private val PUNCTUATION = HermexColors.SyntaxPunctuation.toArgb()
    }
}
