package com.awhisper.prowlmirror

import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.*
import org.junit.Test

class InlineMarkdownTest {
    @Test
    fun terminalTextStylesOnlyCodeAndBoldAndKeepsOtherMarkers() {
        val text = "ls *.kt _tmp_ [doc](https://prowl.cat) ~~x~~ **done** `make`"
        val result = inlineMarkdown(text)
        assertEquals("ls *.kt _tmp_ [doc](https://prowl.cat) ~~x~~ done make", result.text)
        assertEquals(listOf(FontWeight.Bold), result.spanStyles.mapNotNull { it.item.fontWeight })
        assertTrue(result.getStringAnnotations("URL", 0, result.length).isEmpty())
    }

    @Test
    fun chatTextStylesLinksAndEmphasis() {
        val result = inlineMarkdown("see [doc](https://prowl.cat) and *this*", SpanStyle())
        assertEquals("see doc and this", result.text)
        assertEquals("https://prowl.cat", result.getStringAnnotations("URL", 0, result.length).single().item)
        assertEquals(listOf(FontStyle.Italic), result.spanStyles.mapNotNull { it.item.fontStyle })
    }
}
