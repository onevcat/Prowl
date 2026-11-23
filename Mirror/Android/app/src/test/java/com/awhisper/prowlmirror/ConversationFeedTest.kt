package com.awhisper.prowlmirror

import org.junit.Assert.*
import org.junit.Test

class ConversationFeedTest {
    private fun event(sequence: Long, kind: String = "assistant.message") =
        obj("seq" to sequence, "kind" to kind, "source" to "screen", "data" to obj("id" to "screen:prompt"))

    @Test
    fun unqueueOnlyRemovesTheMatchingMessageAndDebugNoticesAreHidden() {
        fun event(seq: Long, kind: String, text: String) =
            ConversationEvent(seq, kind, "transcript", obj("text" to obj("text" to text)), null)
        val rows = chatRows(listOf(
            event(1, "user.queued", "first"),
            event(2, "user.queued", "second"),
            event(3, "user.unqueued", "second"),
            ConversationEvent(4, "notice", "transcript", obj("level" to "debug", "text" to "internal"), null),
        ))
        assertEquals(listOf(1L), rows.map { it.key })
    }

    @Test
    fun oneScreenAnswerAbsorbsOneTranscriptCopyWithinTheSameTurn() {
        fun answer(seq: Long, id: String) = ConversationEvent(
            seq, "prompt.resolved", "transcript", obj("id" to id, "title" to "Proceed?"), null,
        )
        val events = listOf(
            answer(1, "screen:a"), answer(2, "copy"), answer(3, "another"),
            ConversationEvent(4, "user.message", "transcript", obj(), null),
            answer(5, "next-turn"),
        )
        assertEquals(listOf(1L, 3L, 4L, 5L), chatRows(events).map { it.key })
    }

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
