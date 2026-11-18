package com.awhisper.prowlmirror

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatLayoutTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun tabletChatKeepsReadingColumnCenteredAndGroupsToolDetails() {
        val session = Session(Host("fixture"), CoroutineScope(Dispatchers.Main), TransportFactory { _, _, _, _, _, _, _ ->
            error("Layout fixture does not connect")
        })
        val events = listOf(
            ConversationEvent(1, "tool.started", "transcript", obj("id" to "a", "title" to "Read file"), null),
            ConversationEvent(2, "tool.started", "transcript", obj("id" to "b", "title" to "Inspect diff"), null),
            ConversationEvent(3, "assistant.message", "transcript", obj("text" to obj("text" to "# Review ready")), null),
        )
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density * 0.42f, density.fontScale)) {
                MaterialTheme {
                    Box(Modifier.fillMaxSize()) { ConversationReader(session, ConversationFeed(3, events)) }
                }
            }
        }
        rule.onNodeWithText("Review ready").assertIsDisplayed()
        val column = rule.onAllNodesWithTag("chat-reading-column").onFirst().fetchSemanticsNode().boundsInRoot
        val screen = rule.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue(column.width < screen.width * 0.9f)
        assertTrue(kotlin.math.abs(column.center.x - screen.center.x) < 2f)
        rule.onNodeWithText("2 tool calls", substring = true).performClick()
        rule.onNodeWithText("Read file · Running").assertIsDisplayed()
        rule.onNodeWithText("Inspect diff · Running").assertIsDisplayed()
    }
}
