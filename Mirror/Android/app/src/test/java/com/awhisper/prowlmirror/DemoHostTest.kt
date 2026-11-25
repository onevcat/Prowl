package com.awhisper.prowlmirror

import com.google.gson.JsonObject
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
    private class Peer(private val scope: TestScope, val host: DemoHost = DemoHost(scope.backgroundScope)) {
        val packets = mutableListOf<Packet>()
        private val connection = host.transport.connect(
            host.address, "", scope.backgroundScope, { packets += it }, {}, { error(it) }, {},
        )
        var pane = ""
            private set
        private var lease: String? = null

        fun latest(kind: String) =
            packets.filterIsInstance<Packet.Control>().last { it.kind == kind }.payload()

        fun roster(): List<JsonObject> {
            connection.send(control("list"))
            scope.runCurrent()
            return latest("panes").array("panes").map { it.asJsonObject }
        }

        fun subscribe(id: String, representation: String = "conversation-v1") {
            pane = id
            connection.send(control("subscribe", obj("paneID" to id, "representation" to representation)))
            scope.runCurrent()
            lease = latest("subscribed").string("subscriptionID")
        }

        fun run(command: JsonObject): JsonObject {
            val id = uuid()
            connection.send(Commands.request(id, command, lease))
            scope.runCurrent()
            return packets.filterIsInstance<Packet.Control>().filter { it.kind == "commandResult" }
                .map { it.payload().record("commandResponse") }.last { it.string("requestID") == id }.record("response")
        }

        fun command(kind: String, vararg fields: Pair<String, Any?>) =
            run(obj(kind to obj("_0" to obj("pane" to pane, *fields))))

        fun scroll(direction: String) {
            connection.send(control("scroll", obj("direction" to direction, "requestID" to uuid())))
            scope.runCurrent()
        }

        fun screen() = packets.filterIsInstance<Packet.Text>().last().text

        /** The conversation as the app's feed reads it: the snapshot and every later batch. */
        fun feed(): ConversationFeed {
            var feed = ConversationFeed()
            for (packet in packets.filterIsInstance<Packet.Control>()) when (packet.kind) {
                "conversationSnapshot" -> feed = feed.accept(packet.payload(), snapshot = true)
                "conversationEvents" -> feed = feed.accept(packet.payload(), snapshot = false)
            }
            return feed
        }

        fun events() = packets.filterIsInstance<Packet.Control>().filter { it.kind == "conversationEvents" }
            .flatMap { packet -> packet.payload().array("events").map { ConversationEvent.parse(it.asJsonObject) } }

        fun messages(kind: String) = events().filter { it.kind == kind }.map { it.data.record("text").string("text") }
    }

    private fun TestScope.peer(id: String = DemoContent.PaneID.DONE) = Peer(this).apply {
        subscribe(id)
        packets.clear()
    }

    @Test
    fun rosterMatchesTheIosDemo() = runTest {
        val peer = Peer(this)
        val roster = peer.roster().map(Pane::parse)
        assertEquals("Demo Mac", peer.latest("panes").string("hostName"))
        assertEquals(
            listOf(
                listOf("Fix flaky prefetch test", "Kingfisher", "main", "claude", "blocked", "blue"),
                listOf("Scan unused images", "FengNiao", "main", "codex", "working", "purple"),
                listOf("Draft 8.4 release notes", "Kingfisher", "release/8.4", "codex", "done", "blue"),
                listOf("Review sidebar groups", "Prowl", "main", "claude", "idle", "mint"),
                listOf("zsh", "Prowl", "main", null, null, "mint"),
                listOf("swift test", "Kingfisher", "main", null, null, "blue"),
            ),
            roster.map { listOf(it.tabTitle, it.projectName, it.worktreeName, it.agent, it.displayState, it.repositoryColor) },
        )
        assertEquals(listOf("Prowl", "Kingfisher", "FengNiao"), rosterProjects(roster, null).map { it.first })
        assertTrue(roster.all { it.stateChangedAt != null })
        peer.host.close()
    }

    @Test
    fun workingPaneFinishesTheScanByAutoplay() = runTest {
        val peer = Peer(this)
        peer.subscribe(DemoContent.PaneID.WORKING)
        assertEquals("working", peer.feed().agentState)
        assertTrue(peer.feed().events.any { it.kind == "tool.started" && it.data.string("id") == "f3" })
        advanceTimeBy(DemoContent.WORKING_RUNS_FOR + 1)
        assertEquals("succeeded", peer.events().single { it.kind == "tool.completed" }.data.string("status"))
        assertEquals(0, peer.messages("assistant.message").size)
        advanceTimeBy(1_500)
        runCurrent()
        val final = peer.events().single { it.kind == "assistant.message" }
        assertEquals("final", final.data.string("phase"))
        assertTrue(final.data.record("text").string("text").startsWith("I found 6 image assets that nothing uses"))
        assertTrue(final.data.record("text").string("text").contains("| `promo-banner-2025@3x.png` | 1.9 MB | 14 months ago |"))
        assertEquals("idle", peer.feed().agentState)
        assertEquals("done", Pane.parse(peer.roster().single { it.string("id") == DemoContent.PaneID.WORKING }).displayState)
        peer.host.close()
    }

    @Test
    fun blockedPaneExposesItsPermissionPromptAndFinishesWhenAllowed() = runTest {
        val peer = Peer(this)
        peer.subscribe(DemoContent.PaneID.BLOCKED)
        val feed = peer.feed()
        assertEquals("blocked", feed.agentState)
        assertEquals("permission", feed.attentionKind)
        val prompt = feed.openPrompt!!
        assertEquals(DemoContent.BLOCKED_PROMPT_ID, prompt.string("id"))
        assertEquals("permission", prompt.string("kind"))
        assertEquals("Do you want to proceed?", prompt.string("title"))
        assertEquals(listOf("1", "2", "3"), prompt.array("choices").map { it.asJsonObject.string("id") })
        assertEquals("INPUT_NOT_READY", peer.command("agentsInput", "prompt" to "hello").record("error").string("code"))

        assertTrue(peer.command("promptRespond", "prompt" to DemoContent.BLOCKED_PROMPT_ID, "choice" to "1").flag("ok"))
        assertEquals("allowed", peer.events().single { it.kind == "prompt.resolved" }.data.string("outcome"))
        assertNull(peer.feed().openPrompt)
        assertEquals("working", peer.feed().agentState)
        advanceTimeBy(5_701)
        assertEquals("The flaky failure is fixed.",
            peer.messages("assistant.message").single().lines().first())
        assertEquals("idle", peer.feed().agentState)
        assertEquals("done", Pane.parse(peer.roster().single { it.string("id") == DemoContent.PaneID.BLOCKED }).displayState)
        peer.host.close()
    }

    @Test
    fun terminalShowsTheBlockedPromptAndEscapeDeclinesIt() = runTest {
        val peer = Peer(this)
        peer.subscribe(DemoContent.PaneID.BLOCKED, "text-v1")
        assertTrue(peer.screen().endsWith("Do you want to proceed?\n❯ 1. Yes\n" +
            "  2. Yes, and don't ask again for scripts/repeat-tests.sh commands in /Users/demo/Projects/Kingfisher\n" +
            "  3. No, and tell Claude what to do differently (esc)"))
        assertTrue(peer.screen().contains("  scripts/repeat-tests.sh 50 ImagePrefetcherTests"))
        assertEquals(DemoContent.BLOCKED_PROMPT_ID, peer.latest("screenPrompt").record("prompt").string("id"))
        peer.command("agentKeys", "keys" to listOf("esc"))
        assertFalse(peer.latest("screenPrompt").has("prompt"))
        assertTrue(peer.screen().contains("⏺ Bash(scripts/repeat-tests.sh 50 ImagePrefetcherTests)\n  ⎿  The user declined this command."))
        advanceTimeBy(1_001)
        assertTrue(peer.screen().contains("⏺ Okay, I won't run the tests."))
        assertTrue(peer.screen().endsWith("\n>"))
        peer.host.close()
    }

    @Test
    fun terminalPagesTheShellAndRestoresTheTail() = runTest {
        val peer = Peer(this)
        peer.subscribe(DemoContent.PaneID.PROWL_SHELL, "text-v1")
        assertEquals("Prowl main ❯ ", peer.screen().lines().last())
        // Each command adds two lines (it replaces the prompt), so the shell holds more than one screen.
        for (index in 1..40) {
            val sent = peer.run(obj("send" to obj("_0" to obj("selector" to obj("pane" to obj("_0" to peer.pane)),
                "text" to "echo $index"))))
            assertTrue(sent.flag("ok"))
        }
        val tail = peer.screen()
        assertTrue(tail.endsWith("Prowl main ❯ echo 40\ndemo: Commands do not run in the demo. On a paired Mac they run in this pane.\nProwl main ❯ "))
        assertTrue(peer.latest("scrollState").flag("atBottom"))
        assertFalse(peer.latest("scrollState").flag("atTop"))
        peer.scroll("up")
        assertNotEquals(tail, peer.screen())
        assertFalse(peer.latest("scrollState").flag("atBottom"))
        peer.scroll("up")
        assertTrue(peer.latest("scrollState").flag("atTop"))
        assertTrue(peer.screen().startsWith("Prowl main ❯ git status --short"))
        assertEquals(DemoPane.SCREEN_LINES, peer.screen().lines().size)
        peer.scroll("down")
        peer.scroll("down")
        assertEquals(tail, peer.screen())
        peer.host.close()
    }

    @Test
    fun finishesAWorkingTurnAndStartsQueuedMessagesInOrder() = runTest {
        val peer = peer()
        for (message in listOf("first", "second", "third")) peer.command("agentsInput", "prompt" to message)
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
        assertTrue(peer.messages("assistant.message").all { it.startsWith("This is the demo") && "Codex gets this message" in it })
        peer.host.close()
    }

    @Test
    fun interruptFinishesTheRunningToolAndDoesNotDeliverTheCancelledReply() = runTest {
        val peer = peer()
        peer.command("agentsInput", "prompt" to "cancel this")
        advanceTimeBy(2_000)
        runCurrent()
        val tool = peer.events().single { it.kind == "tool.started" }.data.string("id")
        peer.command("agentsInput", "prompt" to "run this next")
        peer.command("agentKeys", "keys" to listOf("ctrl-c"))
        val completed = peer.events().single { it.kind == "tool.completed" }
        assertEquals(tool, completed.data.string("id"))
        assertEquals("interrupted", completed.data.string("status"))
        assertEquals("Interrupted. Tell Codex what to do differently.",
            peer.events().single { it.kind == "notice" }.data.string("text"))
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
    fun stopInterruptsTheWorkingScan() = runTest {
        val peer = peer(DemoContent.PaneID.WORKING)
        peer.command("agentKeys", "keys" to listOf("esc"))
        assertEquals("interrupted", peer.events().single { it.kind == "tool.completed" }.data.string("status"))
        advanceTimeBy(DemoContent.WORKING_RUNS_FOR * 2)
        assertEquals(0, peer.messages("assistant.message").size)
        peer.host.close()
    }

    @Test
    fun closingDemoCancelsPendingReplies() = runTest {
        val peer = peer()
        peer.command("agentsInput", "prompt" to "pending")
        peer.host.close()
        runCurrent()
        assertFalse(backgroundScope.coroutineContext[Job]!!.children.any())
        val beforeClose = peer.events()
        advanceTimeBy(200_000)
        runCurrent()
        assertEquals(beforeClose, peer.events())
    }
}
