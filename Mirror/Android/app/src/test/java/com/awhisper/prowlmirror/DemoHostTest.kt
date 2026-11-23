package com.awhisper.prowlmirror

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DemoHostTest {
    private class Peer(scope: TestScope) {
        val host = DemoHost(scope.backgroundScope)
        private val packets = mutableListOf<Packet>()
        private val connection = host.transport.connect(
            host.address, "", scope.backgroundScope, { packets += it }, {}, { error(it) }, {},
        )
        private val pane: String
        private val lease: String

        init {
            connection.send(control("list"))
            scope.runCurrent()
            pane = latest("panes").array("panes").map { it.asJsonObject }
                .single { it.string("tabTitle") == "Review the release" }.string("id")
            connection.send(control("subscribe", obj("paneID" to pane, "representation" to "conversation-v1")))
            scope.runCurrent()
            lease = latest("subscribed").string("subscriptionID")
            packets.clear()
        }

        private fun latest(kind: String) =
            packets.filterIsInstance<Packet.Control>().last { it.kind == kind }.payload()

        fun command(kind: String, vararg fields: Pair<String, Any?>) {
            connection.send(Commands.request(uuid(), obj(kind to obj("_0" to obj("pane" to pane, *fields))), lease))
        }

        fun events() = packets.filterIsInstance<Packet.Control>().filter { it.kind == "conversationEvents" }
            .flatMap { packet -> packet.payload().array("events").map { ConversationEvent.parse(it.asJsonObject) } }

        fun messages(kind: String) = events().filter { it.kind == kind }.map { it.data.record("text").string("text") }
    }

    @Test
    fun terminalPagesAnAgentViewportAndRestoresTheTail() = runTest {
        val host = DemoHost(backgroundScope)
        val packets = mutableListOf<Packet>()
        val connection = host.transport.connect(
            host.address, "", backgroundScope, { packets += it }, {}, { error(it) }, {},
        )
        fun latest(kind: String) =
            packets.filterIsInstance<Packet.Control>().last { it.kind == kind }.payload()

        connection.send(control("list"))
        runCurrent()
        val roster = latest("panes").array("panes").map { it.asJsonObject }
        assertEquals(6, roster.size)
        assertEquals(3, roster.map { it.string("projectName") }.toSet().size)
        val pane = roster.single { it.string("tabTitle") == "Draft the migration guide" }.string("id")
        connection.send(control("subscribe", obj("paneID" to pane, "representation" to "text-v1")))
        runCurrent()
        val tail = packets.filterIsInstance<Packet.Text>().last().text
        assertTrue(latest("scrollState").flag("atBottom"))
        assertFalse(latest("scrollState").flag("atTop"))
        connection.send(control("scroll", obj("direction" to "up", "requestID" to uuid())))
        runCurrent()
        val earlier = packets.filterIsInstance<Packet.Text>().last().text
        assertNotEquals(tail, earlier)
        assertTrue(earlier.lines().size <= 24)
        assertTrue(latest("scrollState").flag("atTop"))
        assertFalse(latest("scrollState").flag("atBottom"))
        connection.send(control("scroll", obj("direction" to "down", "requestID" to uuid())))
        runCurrent()
        assertEquals(tail, packets.filterIsInstance<Packet.Text>().last().text)
        host.close()
    }

    @Test
    fun finishesAWorkingTurnAndStartsQueuedMessagesInOrder() = runTest {
        val peer = Peer(this)
        for (message in listOf("first", "second", "third")) {
            peer.command("agentsInput", "prompt" to message)
            runCurrent()
        }
        assertEquals(listOf("first"), peer.messages("user.message"))
        assertEquals(listOf("second", "third"), peer.messages("user.queued"))
        advanceTimeBy(3_400)
        runCurrent()
        assertEquals(listOf("second"), peer.messages("user.unqueued"))
        assertEquals(listOf("first", "second"), peer.messages("user.message"))
        advanceTimeBy(6_800)
        runCurrent()
        assertEquals(listOf("second", "third"), peer.messages("user.unqueued"))
        assertEquals(listOf("first", "second", "third"), peer.messages("user.message"))
        assertEquals(3, peer.messages("assistant.message").size)
        peer.host.close()
    }

    @Test
    fun interruptFinishesTheRunningToolAndDoesNotDeliverTheCancelledReply() = runTest {
        val peer = Peer(this)
        peer.command("agentsInput", "prompt" to "cancel this")
        runCurrent()
        advanceTimeBy(2_000)
        runCurrent()
        val tool = peer.events().single { it.kind == "tool.started" }.data.string("id")
        peer.command("agentsInput", "prompt" to "run this next")
        runCurrent()
        peer.command("agentKeys", "keys" to listOf("ctrl-c"))
        runCurrent()
        val completed = peer.events().single { it.kind == "tool.completed" }
        assertEquals(tool, completed.data.string("id"))
        assertEquals("interrupted", completed.data.string("status"))
        assertEquals(listOf("run this next"), peer.messages("user.unqueued"))
        assertEquals(0, peer.messages("assistant.message").size)
        advanceTimeBy(3_400)
        runCurrent()
        assertEquals(1, peer.messages("assistant.message").size)
        assertEquals(listOf("aborted", "completed"),
            peer.events().filter { it.kind == "turn.completed" }.map { it.data.string("status") })
        peer.host.close()
    }

    @Test
    fun closingDemoCancelsPendingReplies() = runTest {
        val peer = Peer(this)
        peer.command("agentsInput", "prompt" to "pending")
        runCurrent()
        peer.host.close()
        runCurrent()
        assertFalse(backgroundScope.coroutineContext[Job]!!.children.any())
        val beforeClose = peer.events()
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals(beforeClose, peer.events())
    }
}
