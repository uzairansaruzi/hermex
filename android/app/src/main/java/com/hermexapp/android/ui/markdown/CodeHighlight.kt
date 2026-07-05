package com.hermexapp.android.ui.markdown

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle

/** Token colors, sourced from the Hermex palette so both light/dark adapt. */
data class CodeColors(
    val keyword: Color,
    val string: Color,
    val comment: Color,
    val number: Color,
)

/**
 * A tiny, dependency-free syntax highlighter for fenced code blocks. It is
 * deliberately approximate — a single forward scan that tags strings, comments,
 * numbers, and a broad keyword set — and never throws on partial/streaming input
 * (an unterminated string or comment just colors to end-of-input). Language is
 * used only to pick comment style and keyword set; unknown languages fall back
 * to a C-like union.
 */
fun highlightCode(code: String, language: String?, colors: CodeColors): AnnotatedString {
    val lang = language?.trim()?.lowercase().orEmpty()
    val keywords = keywordsFor(lang)
    val hashComments = lang in HASH_COMMENT_LANGS || lang.isEmpty()
    val slashComments = lang !in NO_SLASH_COMMENT_LANGS

    return buildAnnotatedString {
        var i = 0
        val n = code.length
        while (i < n) {
            val c = code[i]
            when {
                // Block comment /* ... */
                slashComments && c == '/' && i + 1 < n && code[i + 1] == '*' -> {
                    val end = code.indexOf("*/", i + 2).let { if (it < 0) n else it + 2 }
                    withStyle(SpanStyle(color = colors.comment)) { append(code.substring(i, end)) }
                    i = end
                }
                // Line comment // ...
                slashComments && c == '/' && i + 1 < n && code[i + 1] == '/' -> {
                    val end = code.indexOf('\n', i).let { if (it < 0) n else it }
                    withStyle(SpanStyle(color = colors.comment)) { append(code.substring(i, end)) }
                    i = end
                }
                // Line comment # ...
                hashComments && c == '#' -> {
                    val end = code.indexOf('\n', i).let { if (it < 0) n else it }
                    withStyle(SpanStyle(color = colors.comment)) { append(code.substring(i, end)) }
                    i = end
                }
                // String literal ' " `
                c == '"' || c == '\'' || c == '`' -> {
                    val end = endOfString(code, i, c)
                    withStyle(SpanStyle(color = colors.string)) { append(code.substring(i, end)) }
                    i = end
                }
                // Number
                c.isDigit() -> {
                    var j = i + 1
                    while (j < n && (code[j].isLetterOrDigit() || code[j] == '.' || code[j] == '_')) j++
                    withStyle(SpanStyle(color = colors.number)) { append(code.substring(i, j)) }
                    i = j
                }
                // Identifier / keyword
                c.isLetter() || c == '_' -> {
                    var j = i + 1
                    while (j < n && (code[j].isLetterOrDigit() || code[j] == '_')) j++
                    val word = code.substring(i, j)
                    if (word in keywords) {
                        withStyle(SpanStyle(color = colors.keyword)) { append(word) }
                    } else {
                        append(word)
                    }
                    i = j
                }
                else -> { append(c); i++ }
            }
        }
    }
}

/** Advances past a string literal, honoring backslash escapes. Tolerant of EOF. */
private fun endOfString(code: String, start: Int, quote: Char): Int {
    var i = start + 1
    while (i < code.length) {
        val c = code[i]
        if (c == '\\') { i += 2; continue }
        if (c == quote) return i + 1
        // Unterminated single/double-quoted string ends at the line for safety.
        if ((quote == '"' || quote == '\'') && c == '\n') return i
        i++
    }
    return code.length
}

private val HASH_COMMENT_LANGS = setOf(
    "python", "py", "ruby", "rb", "sh", "bash", "shell", "zsh", "yaml", "yml",
    "toml", "ini", "conf", "makefile", "make", "r", "perl", "pl",
)

// Languages where `//` is NOT a comment (so we don't mis-color paths/regex).
private val NO_SLASH_COMMENT_LANGS = setOf(
    "python", "py", "ruby", "rb", "yaml", "yml", "toml", "ini", "bash", "sh",
    "shell", "zsh", "makefile", "make",
)

private val COMMON_KEYWORDS = setOf(
    "if", "else", "for", "while", "return", "break", "continue", "class",
    "import", "from", "as", "try", "catch", "finally", "throw", "throws",
    "new", "true", "false", "null", "nil", "none", "void", "int", "float",
    "double", "string", "boolean", "bool", "var", "let", "const", "function",
    "def", "fun", "public", "private", "protected", "static", "final", "this",
    "super", "switch", "case", "default", "do", "in", "is", "and", "or", "not",
    "async", "await", "yield", "with", "lambda", "enum", "struct", "interface",
    "extends", "implements", "override", "abstract", "when", "val", "object",
    "package", "type", "typeof", "instanceof", "self", "elif", "pass", "raise",
    "match", "where", "use", "mut", "impl", "trait", "pub", "unsafe",
)

private fun keywordsFor(lang: String): Set<String> = COMMON_KEYWORDS
