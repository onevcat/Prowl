package com.awhisper.prowlmirror

import org.junit.Assert.*
import org.junit.Test

class ConversationFeedTest {
    private fun event(sequence: Long, kind: String = "assistant.message") =
        obj("seq" to sequence, "kind" to kind, "source" to "screen", "data" to obj("id" to "screen:prompt"))

    @Test
    fun snapshotResumesInOrderAndMarksMissingHistory() {
        val snapshot = ConversationFeed().accept(
            obj("sequence" to 20, "gap" to false, "events" to listOf(event(19), event(20))),
            snapshot = true,
        )
        val resumed = snapshot.accept(obj("sequence" to 21, "events" to listOf(event(21))), snapshot = false)
        assertEquals(listOf(19L, 20L, 21L), resumed.events.map { it.sequence })
        val gap = resumed.accept(
            obj("sequence" to 30, "gap" to true, "events" to listOf(event(30))),
            snapshot = true,
        )
        assertTrue(gap.gap)
        assertEquals(listOf(19L, 20L, 21L, 30L), gap.events.map { it.sequence })
    }

    @Test
    fun resolvedPromptCannotBeAnsweredFromOlderEvents() {
        val opened = ConversationFeed().accept(
            obj("sequence" to 1, "gap" to false, "events" to listOf(event(1, "prompt.opened"))),
            snapshot = true,
        )
        assertNotNull(opened.openPrompt)
        assertNull(opened.accept(
            obj("sequence" to 2, "events" to listOf(event(2, "prompt.resolved"))),
            snapshot = false,
        ).openPrompt)
    }
}
