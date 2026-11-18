package com.awhisper.prowlmirror

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

private val headingPattern = Regex("^(#{1,6})[ \\t]+(.+)$")
private val listPattern = Regex("^(\\s*)([-+*]|\\d+[.)])[ \\t]+(.+)$")
private val rulePattern = Regex("^(?:-{3,}|\\*{3,}|_{3,})$")

@Composable
internal fun ChatMarkdown(text: String) {
    val blocks = remember(text) { Document.blocks(text) }
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
                                        Text(
                                            inlineMarkdown(cell), Modifier.width(132.dp).padding(6.dp),
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
    val lines = remember(text) { text.lines() }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        lines.forEach { line ->
            val stripped = line.trim()
            val heading = headingPattern.matchEntire(stripped)
            val list = listPattern.matchEntire(line)
            when {
                stripped.isEmpty() -> Spacer(Modifier.height(4.dp))
                heading != null -> Text(
                    inlineMarkdown(heading.groupValues[2]),
                    style = if (heading.groupValues[1].length <= 2) MaterialTheme.typography.titleLarge
                    else MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                rulePattern.matches(stripped) -> HorizontalDivider()
                stripped.startsWith(">") -> Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.small,
                ) {
                    Text(inlineMarkdown(stripped.drop(1).trimStart()), Modifier.fillMaxWidth().padding(8.dp))
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
                        Text(inlineMarkdown(if (task == "[x] " || task == "[ ] ") entry.drop(4) else entry))
                    }
                }
                else -> Text(inlineMarkdown(line))
            }
        }
    }
}
