package com.hermexapp.android.ui.markdown

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeHighlightTest {

    private val colors = CodeColors(
        keyword = Color(0xFFFFD700),
        string = Color(0xFF34C759),
        comment = Color(0xFF8E8E93),
        number = Color(0xFFFF9F0A),
    )

    /** The full text must always round-trip unchanged — highlighting only styles. */
    @Test
    fun `preserves the exact source text`() {
        val code = "fun main() {\n  val x = 42 // note\n  println(\"hi\")\n}"
        assertEquals(code, highlightCode(code, "kotlin", colors).text)
    }

    @Test
    fun `colors keywords strings numbers and comments`() {
        val code = "val n = 10 // c\nval s = \"hi\""
        val annotated = highlightCode(code, "kotlin", colors)
        fun colorAt(index: Int): Color? =
            annotated.spanStyles.firstOrNull { index >= it.start && index < it.end }?.item?.color

        assertEquals(colors.keyword, colorAt(code.indexOf("val"))) // keyword
        assertEquals(colors.number, colorAt(code.indexOf("10")))   // number
        assertEquals(colors.comment, colorAt(code.indexOf("// c"))) // line comment
        assertEquals(colors.string, colorAt(code.indexOf("\"hi\""))) // string
    }

    @Test
    fun `hash is a comment in python but not in kotlin`() {
        val code = "# a comment"
        val py = highlightCode(code, "python", colors)
        assertTrue(py.spanStyles.any { it.item.color == colors.comment })

        val kt = highlightCode(code, "kotlin", colors)
        assertTrue(kt.spanStyles.none { it.item.color == colors.comment })
    }

    @Test
    fun `never throws on an unterminated string or block comment`() {
        val open = "val x = \"unterminated"
        assertEquals(open, highlightCode(open, "kotlin", colors).text)
        val comment = "/* open comment with no close"
        assertEquals(comment, highlightCode(comment, "kotlin", colors).text)
    }
}
