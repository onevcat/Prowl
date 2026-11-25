package com.onevcat.prowl.mirror

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

private val headingPattern = Regex("^(#{1,6})[ \\t]+(.+)$")
private val listPattern = Regex("^( *)([-+*]|\\d+[.)])[ \\t]+(.+)$", RegexOption.DOT_MATCHES_ALL)
private val rulePattern = Regex("^(?:-{3,}|\\*{3,}|_{3,})$")

@Composable
internal fun ChatMarkdown(text: String) {
    val blocks = remember(text) { Document.blocks(text, splitText = false) }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (block in blocks) {
                when (block) {
                    is Block.Text -> MarkdownLines(block.raw)
                    is Block.Code -> Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        Column(Modifier.fillMaxWidth().padding(10.dp)) {
                            if (block.language.isNotEmpty())
                                Text(block.language, style = MaterialTheme.typography.labelSmall)
                            Text(
                                block.raw, Modifier.horizontalScroll(rememberScrollState()),
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                softWrap = false,
                            )
                        }
                    }
                    is Block.Table -> Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        Column(Modifier.horizontalScroll(rememberScrollState()).padding(8.dp)) {
                            block.rows.forEachIndexed { index, cells ->
                                Row {
                                    cells.forEach { cell ->
                                        MarkdownText(
                                            cell, Modifier.width(132.dp).padding(6.dp),
                                            style = MaterialTheme.typography.bodySmall,
                                            fontWeight = if (index == 0) FontWeight.SemiBold else FontWeight.Normal,
                                        )
                                    }
                                }
                                if (index + 1 < block.rows.size) HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MarkdownLines(text: String) {
    val lines = remember(text) {
        val items = mutableListOf<String>()
        var inList = false
        for (line in text.lines()) {
            if (inList && line.isNotBlank() && (line.startsWith("  ") || line.startsWith("\t")) &&
                !listPattern.matches(line)
            ) items[items.lastIndex] += "\n" + line.trim()
            else {
                items += line
                inList = listPattern.matches(line)
            }
        }
        items
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        lines.forEach { line ->
            val stripped = line.trim()
            val heading = headingPattern.matchEntire(stripped)
            val list = listPattern.matchEntire(line)
            when {
                stripped.isEmpty() -> Spacer(Modifier.height(4.dp))
                heading != null -> MarkdownText(
                    heading.groupValues[2],
                    style = if (heading.groupValues[1].length <= 2) MaterialTheme.typography.titleLarge
                    else MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                rulePattern.matches(stripped) -> HorizontalDivider()
                stripped.startsWith(">") -> Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.small,
                ) {
                    MarkdownText(stripped.drop(1).trimStart(), Modifier.fillMaxWidth().padding(8.dp))
                }
                list != null -> {
                    val entry = list.groupValues[3]
                    val task = entry.take(4).lowercase()
                    val marker = when {
                        task == "[x] " -> "☑"
                        task == "[ ] " -> "☐"
                        list.groupValues[2].length == 1 -> "•"
                        else -> list.groupValues[2]
                    }
                    Row(
                        Modifier.padding(start = (list.groupValues[1].length.coerceAtMost(12) * 4).dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(marker)
                        MarkdownText(if (task == "[x] " || task == "[ ] ") entry.drop(4) else entry)
                    }
                }
                else -> MarkdownText(line)
            }
        }
    }
}

private val inlinePattern = Regex("""`([^`\n]+)`|\[([^\]\n]+)]\((https?://[^\s)]+)\)|\*\*([^*\n]+)\*\*|__([^_\n]+)__|~~([^~\n]+)~~|\*([^*\n]+)\*|(?<!\w)_([^_\n]+)_(?!\w)""")

// Terminal output is rarely Markdown: globs and snake_case names must stay as printed.
private val terminalInlinePattern = Regex("""`([^`\n]+)`|\*\*(.+?)\*\*""")

/** Inline Markdown spans. Without [linkStyle] (terminal text) only code and bold are styled. */
internal fun inlineMarkdown(text: String, linkStyle: SpanStyle? = null): AnnotatedString = buildAnnotatedString {
    var start = 0
    for (match in (if (linkStyle == null) terminalInlinePattern else inlinePattern).findAll(text)) {
        append(text.substring(start, match.range.first))
        val group = match.groups
        when {
            group[1] != null -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(group[1]!!.value) }
            linkStyle == null -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(group[2]!!.value) }
            group[2] != null && group[3] != null -> {
                pushStringAnnotation("URL", group[3]!!.value)
                withStyle(linkStyle) { append(group[2]!!.value) }
                pop()
            }
            group[4] != null || group[5] != null ->
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append((group[4] ?: group[5])!!.value) }
            group[6] != null ->
                withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(group[6]!!.value) }
            else -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append((group[7] ?: group[8])!!.value) }
        }
        start = match.range.last + 1
    }
    append(text.substring(start))
}

@Composable
private fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.bodyLarge,
    fontWeight: FontWeight? = null,
) {
    val uri = LocalUriHandler.current
    val linkColor = MaterialTheme.colorScheme.primary
    val contentColor = LocalContentColor.current
    val parsed = remember(text, linkColor) {
        inlineMarkdown(text, SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
    }
    if (parsed.getStringAnnotations("URL", 0, parsed.length).isEmpty()) {
        Text(parsed, modifier, style = style, fontWeight = fontWeight)
    } else {
        ClickableText(parsed, modifier, style = style.copy(color = contentColor, fontWeight = fontWeight ?: style.fontWeight)) { offset ->
            parsed.getStringAnnotations("URL", offset, offset).firstOrNull()?.let {
                runCatching { uri.openUri(it.item) }
            }
        }
    }
}
