package com.awhisper.prowlmirror

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SessionTest {
    private class Peer(
        val receive: (Packet) -> Unit,
        val ready: (Host) -> Unit,
        val closed: (String) -> Unit,
    ) : Transport {
        val sent = mutableListOf<Packet.Control>()
        var stopped = false

        override fun send(message: Packet.Control) {
            sent += message
        }

        override fun close() {
            stopped = true
        }
    }

    private class Fixture(val scope: CoroutineScope) {
        val peers = mutableListOf<Peer>()
        val host = Host("host", credential = Credential(uuid(), uuid(), "unused"))
        var pane = Pane(uuid(), "Pane", "/tmp", false)
        val run = uuid()
        val lease = uuid()
        val session =
            Session(
                host,
                scope,
                TransportFactory { _, _, _, receive, ready, close, _ ->
                    Peer(receive, ready, close).also { peers += it }
                },
            )
        val peer
            get() = peers.last()

        fun ready(
            interactive: Boolean = true,
            remoteScroll: Boolean = false,
            scrollState: Boolean = false,
            conversation: Boolean = false,
            refresh: Boolean = true,
            text: Boolean = true,
        ) {
            peer.ready(host)
            peer.receive(
                control(
                    "panes",
                    obj(
                        "panes" to listOf(pane),
                        "capabilities" to (listOfNotNull("text-v1".takeIf { text }, "launch-profile", "history", "refresh".takeIf { refresh }) +
                            (if (interactive) listOf("agent-input") else emptyList()) +
                            (if (remoteScroll) listOf("remote-scroll") else emptyList()) +
                            (if (scrollState) listOf("scroll-state-v1") else emptyList()) +
                            (if (conversation) listOf("conversation-v1") else emptyList())),
                        "hostRunID" to run,
                    ),
                )
            )
        }

        fun live(remoteScroll: Boolean = false, scrollState: Boolean = false, firstFrame: Boolean = true) {
            session.connect()
            ready(remoteScroll = remoteScroll, scrollState = scrollState)
            session.choose(pane)
            subscribed()
            if (firstFrame) frame(scrollState = scrollState)
        }

        fun frame(text: String = "", scrollState: Boolean = false, subscription: String = lease) {
            if (scrollState)
                peer.receive(control("scrollState", obj("subscriptionID" to subscription, "sequence" to 1)))
            peer.receive(Packet.Text(subscription, 1, 80, 24, false, text))
        }

        fun subscribed(subscription: String = lease) {
            peer.receive(
                control(
                    "subscribed",
                    obj("paneID" to pane.id, "subscriptionID" to subscription, "hostRunID" to run),
                )
            )
        }

        fun answer(id: String, response: com.google.gson.JsonObject) {
            peer.receive(
                control(
                    "commandResult",
                    obj("commandResponse" to obj("requestID" to id, "response" to response)),
                )
            )
        }

        fun listing(agent: String? = "codex") {
            val id = peer.sent.last { it.kind == "command" }.payload().record("commandRequest").string("requestID")
            answer(
                id,
                obj(
                    "ok" to true,
                    "data" to
                        obj(
                            "items" to
                                listOf(
                                    obj(
                                        "pane" to obj("id" to pane.id, "agent" to agent),
                                        "task" to obj("status" to "idle"),
                                    )
                                )
                        ),
                ),
            )
        }
    }

    @Test
    fun leaseAloneDoesNotEnableInputAndOldHostDoesNotReceiveRefresh() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready(refresh = false)
        f.session.choose(f.pane)
        f.subscribed()
        f.session.setDraft("hello")
        assertEquals(Status.subscribing, f.session.state.value.status)
        assertFalse(f.session.state.value.canSend)
        f.frame()
        assertEquals(Status.live, f.session.state.value.status)
        assertTrue(f.session.state.value.canSend)
        f.session.foreground()
        assertFalse(f.peer.sent.any { it.kind == "refresh" })
        f.session.close()
    }

    @Test
    fun revokedCredentialStopsRosterRetries() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.peer.closed(UNRECOGNIZED_DEVICE)
        assertTrue(f.session.state.value.needsPairing)
        advanceTimeBy(20_000)
        assertEquals(1, f.peers.size)
        f.session.close()
    }

    @Test
    fun oldHostStillListsPanesButCannotOpenATextMirror() = runTest {
        val roster = Fixture(backgroundScope)
        roster.session.connect()
        roster.ready(text = false)
        assertEquals(Status.choosing, roster.session.state.value.status)
        assertEquals(listOf(roster.pane), roster.session.state.value.panes)
        roster.session.close()

        val detail = Fixture(backgroundScope)
        detail.session.choose(detail.pane)
        detail.session.connect()
        detail.ready(text = false)
        assertEquals(Status.incompatible, detail.session.state.value.status)
        assertFalse(detail.peer.sent.any { it.kind == "subscribe" })
        assertTrue(detail.peer.stopped)
        detail.session.close()
    }

    @Test
    fun ignoresTheFirstTwoStaleBusyFlagsAfterReleasingItsOwnLease() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(busy = true)
        f.session.connect()
        f.ready()
        f.session.releasePane(f.pane.id)
        assertFalse(f.session.state.value.panes.single().busy)
        repeat(2) {
            f.ready()
            assertFalse(f.session.state.value.panes.single().busy)
        }
        f.ready()
        assertTrue(f.session.state.value.panes.single().busy)
        f.session.close()
    }

    @Test
    fun preservesTheLaunchedAgentUntilTheHostDetectsItOrTheExpectationExpires() = runTest {
        val f = Fixture(backgroundScope)
        val launched = f.pane.copy(agent = "codex", subtitle = "Codex")
        f.session.choose(launched, launched = true)
        f.session.connect()
        f.ready()
        assertEquals("codex", f.session.state.value.pane?.agent)
        val shell = f.pane.copy(conversation = "unsupported")
        f.session.updatePane(shell)
        assertEquals("Codex", f.session.state.value.pane?.subtitle)
        assertNull(f.session.state.value.pane?.conversation)
        advanceTimeBy(30_000)
        runCurrent()
        assertEquals(shell, f.session.state.value.pane)
        f.session.close()
    }

    @Test
    fun aConnectedRosterPollsAndSendsOneCommandAtATime() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready()
        val first = async { f.session.command(Commands.list()) }
        runCurrent()
        val second = runCatching { f.session.command(Commands.profiles()) }
        assertEquals(HOST_BUSY, second.exceptionOrNull()?.message)
        val requests = f.peer.sent.filter { it.kind == "command" }
            .map { it.payload().record("commandRequest").string("requestID") }
        assertEquals(1, requests.size)
        f.answer(requests[0], obj("name" to "list"))
        assertEquals("list", first.await().string("name"))
        val third = async { f.session.command(Commands.profiles()) }
        runCurrent()
        f.answer(f.peer.sent.last().payload().record("commandRequest").string("requestID"), obj("name" to "profiles"))
        assertEquals("profiles", third.await().string("name"))
        advanceTimeBy(3_000)
        runCurrent()
        assertEquals(2, f.peer.sent.count { it.kind == "list" })
        f.session.close()
    }

    @Test
    fun aTimedOutCommandHoldsTheHostUntilItsLateReply() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready()
        val first = async { runCatching { f.session.command(Commands.list()) } }
        runCurrent()
        val late = f.peer.sent.last().payload().record("commandRequest").string("requestID")
        advanceTimeBy(30_001)
        runCurrent()
        assertTrue(first.await().exceptionOrNull() is TimeoutCancellationException)
        assertEquals(HOST_BUSY, runCatching { f.session.command(Commands.profiles()) }.exceptionOrNull()?.message)
        assertEquals(1, f.peer.sent.count { it.kind == "command" })
        f.answer(late, obj("name" to "list"))
        assertFalse(f.peer.stopped)
        assertEquals(Status.choosing, f.session.state.value.status)
        val next = async { f.session.command(Commands.profiles()) }
        runCurrent()
        assertEquals(2, f.peer.sent.count { it.kind == "command" })
        f.answer(f.peer.sent.last().payload().record("commandRequest").string("requestID"), obj("name" to "profiles"))
        assertEquals("profiles", next.await().string("name"))
        f.session.close()
    }

    @Test
    fun aMessageInputHoldsTheHostUntilItsReceipt() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("Review")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        val input = f.peer.sent.last().payload().record("commandRequest").string("requestID")
        assertEquals(HOST_BUSY, runCatching { f.session.command(Commands.list()) }.exceptionOrNull()?.message)
        f.answer(input, obj("ok" to true, "command" to "agents.input",
            "data" to obj("input" to obj("bytes" to 6, "trailing_enter_sent" to true))))
        assertEquals(Delivery.ACCEPTED, f.session.state.value.delivery)
        val next = async { f.session.command(Commands.list()) }
        runCurrent()
        assertEquals(3, f.peer.sent.count { it.kind == "command" })
        next.cancel()
        f.session.close()
    }

    @Test
    fun aLeaseChangeDuringTheListingRejectsTheMessageWithoutSendingIt() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(conversation = "pending")
        f.session.connect()
        f.ready(conversation = true)
        f.session.choose(f.pane)
        f.subscribed()
        f.frame()
        f.session.setDraft("Review")
        f.session.submit()
        runCurrent()
        f.session.updatePane(f.pane.copy(conversation = "available"))
        assertEquals("conversation-v1", f.peer.sent.last().payload().string("representation"))
        f.listing()
        runCurrent()
        assertEquals(Delivery.REJECTED, f.session.state.value.delivery)
        assertEquals("Review", f.session.state.value.draft)
        assertEquals(1, f.peer.sent.count { it.kind == "command" })
        f.session.close()
    }

    @Test
    fun unresponsiveRosterTimesOutAndRetries() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.peer.ready(f.host)
        advanceTimeBy(10_000)
        runCurrent()
        assertTrue(f.peer.stopped)
        assertEquals(Status.disconnected, f.session.state.value.status)
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(2, f.peers.size)
        f.session.close()
    }

    @Test
    fun conversationAndTerminalShareConnectionAndResumeAtLastAck() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(conversation = "available")
        f.session.connect()
        f.ready(conversation = true)
        f.session.choose(f.pane)
        assertEquals("conversation-v1", f.peer.sent.last().payload().string("representation"))
        f.subscribed()
        val message = obj("seq" to 5, "source" to "transcript", "kind" to "assistant.message", "data" to obj())
        f.peer.receive(control("conversationSnapshot", obj(
            "subscriptionID" to f.lease, "sequence" to 5, "gap" to false, "events" to listOf(message),
        )))
        assertEquals("acknowledge", f.peer.sent.last().kind)
        assertEquals(5L, f.peer.sent.last().payload().longInteger("sequence"))
        f.session.showChat(false)
        assertEquals("text-v1", f.peer.sent.last().payload().string("representation"))
        f.subscribed()
        f.frame()
        f.session.showChat(true)
        assertEquals("conversation-v1", f.peer.sent.last().payload().string("representation"))
        assertEquals(5L, f.peer.sent.last().payload().longInteger("since"))
        assertEquals(1, f.peers.size)
        f.session.close()
    }

    @Test
    fun modeSwitchWaitsForFirstFrameAndAcknowledgesItBeforeResubscribing() = runTest {
        for (switchBeforeLease in listOf(true, false)) {
            val f = Fixture(backgroundScope)
            f.pane = f.pane.copy(conversation = "available")
            f.session.connect()
            f.ready(conversation = true)
            f.session.choose(f.pane)
            if (!switchBeforeLease) f.subscribed()
            f.session.showChat(false)
            assertEquals(1, f.peer.sent.count { it.kind == "subscribe" })
            if (switchBeforeLease) f.subscribed()
            val message = obj("seq" to 1, "source" to "transcript", "kind" to "assistant.message", "data" to obj())
            f.peer.receive(control("conversationSnapshot", obj(
                "subscriptionID" to f.lease, "sequence" to 1, "gap" to false, "events" to listOf(message),
            )))
            assertEquals(listOf("acknowledge", "subscribe"), f.peer.sent.takeLast(2).map { it.kind })
            assertEquals("text-v1", f.peer.sent.last().payload().string("representation"))
            val terminal = uuid()
            f.subscribed(terminal)
            f.frame("terminal", subscription = terminal)
            assertEquals(Status.live, f.session.state.value.status)
            assertEquals("terminal", f.session.state.value.text)
            assertFalse(f.peer.stopped)
            f.session.close()
        }
    }

    @Test
    fun oldHistoryRepliesDoNotDisconnectOrPopulateChat() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(conversation = "pending")
        f.session.connect()
        f.ready(conversation = true)
        f.session.choose(f.pane)
        f.subscribed()
        f.frame()
        f.session.loadHistory(refresh = true)
        assertTrue(f.session.state.value.loadingHistory)
        f.session.showChat(true)
        assertFalse(f.session.state.value.loadingHistory)
        f.peer.receive(control("historyPage", obj(
            "subscriptionID" to f.lease, "historyID" to uuid(), "offset" to 0,
            "total" to 1, "capturedAt" to 10, "truncated" to false, "lines" to listOf("old history"),
        )))
        val chat = uuid()
        f.subscribed(chat)
        f.peer.receive(control("failure", obj("subscriptionID" to f.lease, "error" to "HISTORY_UNAVAILABLE")))
        f.peer.receive(control("conversationSnapshot", obj(
            "subscriptionID" to chat, "sequence" to 0, "gap" to false, "events" to emptyList<Any>(),
        )))
        assertEquals(Status.live, f.session.state.value.status)
        assertTrue(f.session.state.value.chat)
        assertTrue(f.session.state.value.history.isEmpty())
        assertFalse(f.peer.stopped)
        f.session.close()
    }

    @Test
    fun reconnectResumesChatWhileHostIsStillDetectingTheConversation() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(conversation = "available")
        f.session.connect()
        f.ready(conversation = true)
        f.session.choose(f.pane)
        f.subscribed()
        val message = obj("seq" to 1, "source" to "transcript", "kind" to "assistant.message", "data" to obj())
        f.peer.receive(control("conversationSnapshot", obj(
            "subscriptionID" to f.lease, "sequence" to 1, "gap" to false, "events" to listOf(message),
        )))
        f.peer.closed("Connection lost")
        f.pane = f.pane.copy(conversation = "pending")
        f.session.retry()
        f.ready(conversation = true)
        val request = f.peer.sent.last().payload()
        assertEquals("conversation-v1", request.string("representation"))
        assertEquals(1L, request.longInteger("since"))
        f.peer.receive(control("failure", obj("error" to "CONVERSATION_UNSUPPORTED")))
        assertEquals("text-v1", f.peer.sent.last().payload().string("representation"))
        f.subscribed()
        f.frame()
        assertEquals(Status.live, f.session.state.value.status)
        assertFalse(f.session.state.value.chat)
        f.session.close()
    }

    @Test
    fun freshConversationSnapshotReplacesPendingRowsButResumeKeepsMessages() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(conversation = "pending")
        f.session.connect()
        f.ready(conversation = true)
        f.session.choose(f.pane)
        f.subscribed()
        f.frame()
        f.session.showChat(true)

        fun snapshot(subscription: String, sequence: Long, gap: Boolean, vararg events: com.google.gson.JsonObject) {
            f.peer.receive(control("conversationSnapshot", obj(
                "subscriptionID" to subscription, "sequence" to sequence, "gap" to gap, "events" to events.toList(),
            )))
        }
        fun event(sequence: Long, kind: String, text: String? = null) =
            obj("seq" to sequence, "kind" to kind, "source" to "transcript", "data" to obj(
                "text" to text?.let { obj("text" to it) },
            ))
        fun rows() = f.session.state.value.conversation.events.map { it.kind }

        val chat = uuid()
        f.subscribed(chat)
        snapshot(chat, 1, false, event(1, "session.pending"))
        assertEquals(listOf("session.pending"), rows())
        snapshot(chat, 5, true, event(3, "session.started"), event(4, "user.message", "hello"),
            event(5, "assistant.message", "Hi"))
        assertEquals(listOf("session.started", "user.message", "assistant.message"), rows())

        f.peer.closed("Connection lost")
        f.session.retry()
        f.ready(conversation = true)
        assertEquals(5L, f.peer.sent.last().payload().longInteger("since"))
        val resumed = uuid()
        f.subscribed(resumed)
        snapshot(resumed, 6, false, event(6, "assistant.message", "Welcome back"))
        assertEquals(listOf("session.started", "user.message", "assistant.message", "assistant.message"), rows())
        assertEquals(Status.live, f.session.state.value.status)
        f.session.close()
    }

    @Test
    fun scrollBoundsAreOptedInAndCommitWithTheirFrame() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true, scrollState = true, firstFrame = false)
        assertTrue(f.peer.sent.last { it.kind == "subscribe" }.payload().flag("includeScrollState"))
        f.peer.receive(control("scrollState", obj(
            "subscriptionID" to f.lease, "sequence" to 1, "atTop" to true, "atBottom" to false,
        )))
        assertFalse(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "same viewport"))
        assertFalse(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.DOWN))
        f.session.scrollRemote(ScrollDirection.UP)
        assertFalse(f.peer.sent.any { it.kind == "scroll" })
        f.peer.receive(control("scrollState", obj(
            "subscriptionID" to f.lease, "sequence" to 2, "atTop" to false, "atBottom" to true,
        )))
        assertFalse(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, "same viewport"))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        assertFalse(f.session.state.value.canScrollRemote(ScrollDirection.DOWN))
        f.session.scrollRemote(ScrollDirection.DOWN)
        assertFalse(f.peer.sent.any { it.kind == "scroll" })
        // Missing/null bounds mean unknown, never a boundary inferred from identical text.
        val unknown = obj("subscriptionID" to f.lease, "sequence" to 3)
        unknown.add("atBottom", com.google.gson.JsonNull.INSTANCE)
        f.peer.receive(control("scrollState", unknown))
        f.peer.receive(Packet.Text(f.lease, 3, 80, 24, false, "same viewport"))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.DOWN))
        f.session.close()
    }

    @Test
    fun malformedOrUnpairedScrollStateDisconnects() = runTest {
        for (failure in listOf("missing", "wrong-lease", "wrong-sequence", "duplicate", "invalid-flag", "stale")) {
            val f = Fixture(backgroundScope)
            f.live(remoteScroll = true, scrollState = true, firstFrame = false)
            val payload = obj("subscriptionID" to f.lease, "sequence" to 1, "atTop" to true)
            when (failure) {
                "wrong-lease" -> payload.addProperty("subscriptionID", uuid())
                "wrong-sequence" -> payload.addProperty("sequence", 2)
                "invalid-flag" -> payload.addProperty("atTop", "true")
                "stale" -> payload.addProperty("sequence", 0)
            }
            if (failure != "missing") f.peer.receive(control("scrollState", payload))
            if (failure == "duplicate") f.peer.receive(control("scrollState", payload))
            f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "screen"))
            assertEquals(failure, Status.disconnected, f.session.state.value.status)
            assertTrue(f.peer.stopped)
            f.session.close()
        }
    }

    @Test
    fun scrollBoundsResetOnReconnectAndOlderHostsNeedNoMetadata() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true, scrollState = true, firstFrame = false)
        f.peer.receive(control("scrollState", obj(
            "subscriptionID" to f.lease, "sequence" to 1, "atTop" to true, "atBottom" to true,
        )))
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "screen"))
        assertFalse(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        f.peer.receive(control("scrollState", obj("subscriptionID" to f.lease, "sequence" to 2)))
        f.peer.closed("Network lost")
        assertEquals(ScrollBounds(), f.session.state.value.scrollBounds)
        f.session.retry()
        f.ready(remoteScroll = true)
        assertFalse(f.peer.sent.last { it.kind == "subscribe" }.payload().has("includeScrollState"))
        f.subscribed()
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "screen"))
        assertEquals(Status.live, f.session.state.value.status)
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.DOWN))
        f.session.close()
    }

    @Test
    fun remoteScrollRequiresCapabilityAndLiveView() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.scrollRemote(ScrollDirection.UP)
        assertFalse(f.session.state.value.canScrollRemote)
        assertFalse(f.peer.sent.any { it.kind == "scroll" })
        f.ready(remoteScroll = true)
        assertTrue(f.session.state.value.canScrollRemote)
        f.session.loadHistory()
        f.session.scrollRemote(ScrollDirection.DOWN)
        assertFalse(f.peer.sent.any { it.kind == "scroll" })
        f.session.close()
    }

    @Test
    fun remoteScrollIsSingleFlightAndCompletesOnlyAfterItsFrame() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true, firstFrame = false)
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "screen"))
        f.session.scrollRemote(ScrollDirection.UP)
        val request = f.peer.sent.last().payload()
        assertEquals("up", request.string("direction"))
        assertEquals(f.lease, request.string("subscriptionID"))
        assertEquals(ScrollDirection.UP, f.session.state.value.scrolling)
        assertFalse(f.session.state.value.follow)
        f.session.scrollRemote(ScrollDirection.DOWN)
        assertEquals(1, f.peer.sent.count { it.kind == "scroll" })
        // Even at a boundary, Host returns a fresh sequence for the unchanged screen.
        f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, "screen"))
        assertEquals(ScrollDirection.UP, f.session.state.value.scrolling)
        f.peer.receive(control("scrollResult", obj(
            "requestID" to request.string("requestID"),
            "subscriptionID" to f.lease,
            "sequence" to 2,
        )))
        assertNull(f.session.state.value.scrolling)
        assertEquals(ScrollDirection.UP, f.session.state.value.scrollCompletion?.direction)
        f.session.consumeScrollCompletion(uuid())
        assertNotNull(f.session.state.value.scrollCompletion)
        f.session.consumeScrollCompletion(request.string("requestID"))
        assertNull(f.session.state.value.scrollCompletion)
        f.session.consumeScrollCompletion(request.string("requestID"))
        assertNull(f.session.state.value.scrollCompletion)
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.UP))
        assertTrue(f.session.state.value.canScrollRemote(ScrollDirection.DOWN))
        assertFalse(f.session.state.value.follow)
        assertEquals(Status.live, f.session.state.value.status)
        advanceTimeBy(6_000)
        assertNull(f.session.state.value.error)
        f.session.close()
    }

    @Test
    fun remoteScrollRejectsMissingStaleOrInvalidFrameSequence() = runTest {
        for (sequence in listOf(0L, 1L, 3L, -1L)) {
            val f = Fixture(backgroundScope)
            f.live(remoteScroll = true, firstFrame = false)
            f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "before"))
            f.session.scrollRemote(ScrollDirection.DOWN)
            val requestID = f.peer.sent.last().payload().string("requestID")
            f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, "after"))
            f.peer.receive(control("scrollResult", obj(
                "requestID" to requestID,
                "subscriptionID" to f.lease,
                "sequence" to sequence,
            )))
            assertEquals(Status.disconnected, f.session.state.value.status)
            assertNull(f.session.state.value.scrolling)
            f.session.close()
        }
    }

    @Test
    fun remoteScrollTimeoutDoesNotReplayAndLateMessagesCannotFinishNextRequest() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true)
        f.session.scrollRemote(ScrollDirection.UP)
        val oldID = f.peer.sent.last().payload().string("requestID")
        runCurrent()
        advanceTimeBy(5_000)
        runCurrent()
        assertNull(f.session.state.value.scrolling)
        assertEquals(Status.live, f.session.state.value.status)
        assertTrue(f.session.state.value.scrollError!!.contains("timed out"))
        assertEquals(1, f.peer.sent.count { it.kind == "scroll" })
        f.session.scrollRemote(ScrollDirection.DOWN)
        val newID = f.peer.sent.last().payload().string("requestID")
        f.peer.receive(control("scrollResult", obj(
            "requestID" to oldID, "subscriptionID" to f.lease, "sequence" to 2,
        )))
        f.peer.receive(control("scrollResult", obj(
            "requestID" to newID, "subscriptionID" to uuid(), "sequence" to 2,
        )))
        f.peer.receive(control("failure", obj(
            "requestID" to oldID, "subscriptionID" to f.lease,
            "error" to "SCROLL_UNAVAILABLE: old request",
        )))
        assertEquals(ScrollDirection.DOWN, f.session.state.value.scrolling)
        f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, "next"))
        f.peer.receive(control("scrollResult", obj(
            "requestID" to newID, "subscriptionID" to f.lease, "sequence" to 2,
        )))
        assertEquals(ScrollDirection.DOWN, f.session.state.value.scrollCompletion?.direction)
        f.session.close()
    }

    @Test
    fun remoteScrollFailuresKeepConnectionAndHistoryAvailable() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true)
        for (reason in listOf("SCROLL_UNAVAILABLE", "SCROLL_BUSY")) {
            f.session.scrollRemote(ScrollDirection.UP)
            val requestID = f.peer.sent.last().payload().string("requestID")
            f.peer.receive(control("failure", obj(
                "requestID" to requestID, "subscriptionID" to f.lease,
                "error" to "$reason: retry later",
            )))
            assertNull(f.session.state.value.scrolling)
            assertEquals(Status.live, f.session.state.value.status)
            assertFalse(f.peer.stopped)
        }
        f.session.loadHistory()
        assertTrue(f.session.state.value.loadingHistory)
        assertEquals("history", f.peer.sent.last().kind)
        f.session.close()
    }

    @Test
    fun remoteScrollIsClearedOnDisconnectWithoutAutomaticReplay() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true)
        f.session.scrollRemote(ScrollDirection.UP)
        f.peer.closed("Network lost")
        assertNull(f.session.state.value.scrolling)
        f.session.retry()
        f.ready(remoteScroll = true)
        f.subscribed()
        f.frame()
        assertFalse(f.peer.sent.any { it.kind == "scroll" })
        advanceTimeBy(6_000)
        assertNull(f.session.state.value.error)
        assertEquals(Status.live, f.session.state.value.status)
        f.session.close()
    }

    @Test
    fun enteringHistoryClearsScrollAndIgnoresItsLateResult() = runTest {
        val f = Fixture(backgroundScope)
        f.live(remoteScroll = true)
        f.session.scrollRemote(ScrollDirection.UP)
        val requestID = f.peer.sent.last().payload().string("requestID")
        f.session.loadHistory()
        assertNull(f.session.state.value.scrolling)
        f.peer.receive(control("scrollResult", obj(
            "requestID" to requestID, "subscriptionID" to f.lease, "sequence" to 1,
        )))
        assertTrue(f.session.state.value.showsHistory)
        assertNull(f.session.state.value.scrollCompletion)
        assertEquals(Status.live, f.session.state.value.status)
        f.session.close()
    }

    @Test
    fun savedEnrollmentIsUsedByRetryBeforeRuntimeReady() = runTest {
        val attempted = mutableListOf<Pair<Host, String>>()
        val enrollments = mutableListOf<(Host) -> Unit>()
        val failures = mutableListOf<(String) -> Unit>()
        val session = Session(
            Host("host"), backgroundScope,
            TransportFactory { host, code, _, _, _, closed, enrolled ->
                attempted += host to code
                enrollments += enrolled
                failures += closed
                object : Transport {
                    override fun send(message: Packet.Control) {}
                    override fun close() {}
                }
            },
        )
        session.connect("ABCD2345")
        val saved = Host("host", credential = Credential(uuid(), uuid(), "saved"))
        enrollments.single()(saved)
        assertEquals(Status.connecting, session.state.value.status)
        assertEquals(saved, session.state.value.host)
        failures.single()("Runtime reconnect failed")
        session.retry()
        assertEquals(saved, attempted.last().first)
        assertEquals("", attempted.last().second)
        enrollments.first()(Host("stale"))
        assertEquals(saved, session.state.value.host)
        session.close()
    }

    @Test
    fun freshPairingCodeDoesNotReuseOldCredential() = runTest {
        val old = Host("host", credential = Credential(uuid(), uuid(), "old"))
        var attempted: Host? = null
        val session = Session(
            old, backgroundScope,
            TransportFactory { host, _, _, _, _, _, _ ->
                attempted = host
                object : Transport {
                    override fun send(message: Packet.Control) {}
                    override fun close() {}
                }
            },
        )
        session.connect("ABCD2345")
        assertNull(attempted?.credential)
        assertNull(session.state.value.host.credential)
        session.close()
    }

    @Test
    fun ordinarySelectionDoesNotTakeOverAStaleFreePane() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready()
        f.session.choose(f.pane)
        assertEquals("ifFree", f.peer.sent.last().payload().string("intent"))
        f.peer.receive(control("failure", obj("error" to "PANE_BUSY: occupied")))
        assertEquals(Status.takenOver, f.session.state.value.status)
        f.session.takeOver()
        f.ready()
        assertEquals("takeover", f.peer.sent.last().payload().string("intent"))
        f.session.close()
    }

    @Test
    fun explicitBusySelectionRequestsTakeover() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready()
        f.session.choose(f.pane.copy(busy = true), takeover = true)
        assertEquals("takeover", f.peer.sent.last().payload().string("intent"))
        f.session.close()
    }

    @Test
    fun replacementAckAndStaleLease() = runTest {
        val f = Fixture(backgroundScope)
        f.live(firstFrame = false)
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "old"))
        f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, ""))
        assertEquals("", f.session.state.value.text)
        assertEquals("acknowledge", f.peer.sent.last().kind)
        f.peer.receive(Packet.Text(uuid(), 3, 80, 24, false, "wrong"))
        assertEquals(Status.disconnected, f.session.state.value.status)
        f.session.close()
    }

    @Test
    fun shellWithoutCapabilityPreservesDraftAndSendsNoMutation() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("echo preserved")
        f.session.submit()
        runCurrent()
        f.listing(agent = null)
        runCurrent()
        assertEquals(Delivery.REJECTED, f.session.state.value.delivery)
        assertEquals("echo preserved", f.session.state.value.draft)
        assertTrue(f.session.state.value.hint.contains("empty command line"))
        assertEquals(1, f.peer.sent.count { it.kind == "command" })
        val request = f.peer.sent.last().payload().record("commandRequest")
        assertTrue(request.record("request").record("command").has("list"))
        f.session.close()
    }

    @Test
    fun agentInputDoesNotRequireShellCapability() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("Review")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        assertEquals(Delivery.PENDING, f.session.state.value.delivery)
        val request = f.peer.sent.last().payload().record("commandRequest")
        assertTrue(request.record("request").record("command").has("agentsInput"))
        assertEquals(2, f.peer.sent.count { it.kind == "command" })
        f.session.close()
    }

    @Test
    fun oldHostNeverFallsBackToDispatch() = runTest {
        val f = Fixture(backgroundScope)
        f.session.connect()
        f.ready(interactive = false)
        f.session.choose(f.pane)
        f.subscribed()
        f.frame()
        f.session.setDraft("hello")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        assertEquals(Delivery.REJECTED, f.session.state.value.delivery)
        assertEquals("hello", f.session.state.value.draft)
        assertTrue(f.session.state.value.hint.contains("Update Host"))
        assertEquals(1, f.peer.sent.count { it.kind == "command" })
        f.session.close()
    }

    @Test
    fun broughtDraftAndItsDiscardPolicySurviveARejectedSend() = runTest {
        val f = Fixture(backgroundScope)
        f.pane = f.pane.copy(agent = "codex")
        f.live()
        f.session.setDraft("local follow-up")

        fun submit(): com.google.gson.JsonObject {
            f.session.submit()
            runCurrent()
            f.listing()
            runCurrent()
            return f.peer.sent.last().payload().record("commandRequest")
        }
        val initial = submit()
        f.answer(initial.string("requestID"), obj("ok" to false, "error" to obj(
            "code" to "INPUT_NOT_READY", "message" to "Host draft",
            "details" to obj("input" to obj(
                "reason" to "draft", "discardable" to true,
                "draft" to obj("text" to "host draft", "is_complete" to true),
            )),
        )))
        f.session.bringHostDraft(requireNotNull(f.session.state.value.hostDraft))
        assertEquals("host draft\nlocal follow-up", f.session.state.value.draft)
        val firstTry = submit()
        assertEquals("discard", firstTry.record("request").record("command").record("agentsInput").record("_0").string("on_draft"))
        f.answer(firstTry.string("requestID"), obj("ok" to false, "error" to obj(
            "code" to "INPUT_NOT_READY", "message" to "Agent is busy",
        )))
        val retry = submit()
        val input = retry.record("request").record("command").record("agentsInput").record("_0")
        assertEquals("discard", input.string("on_draft"))
        assertEquals("host draft\nlocal follow-up", input.string("prompt"))
        f.answer(retry.string("requestID"), obj("ok" to true, "command" to "agents.input", "data" to obj(
            "input" to obj("bytes" to input.string("prompt").toByteArray().size, "trailing_enter_sent" to true),
        )))
        assertEquals(Delivery.ACCEPTED, f.session.state.value.delivery)
        assertEquals("", f.session.state.value.draft)
        assertNull(f.session.state.value.broughtDraftPolicy)
        f.session.close()
    }

    @Test
    fun oldReceiptDoesNotEraseNewDraft() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("hello")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        val id = f.peer.sent.last().payload().record("commandRequest").string("requestID")
        f.session.setDraft("new draft")
        f.answer(id, obj("ok" to true, "command" to "agents.input", "data" to obj("input" to obj("bytes" to 5, "trailing_enter_sent" to true))))
        assertEquals(Delivery.ACCEPTED, f.session.state.value.delivery)
        assertEquals("new draft", f.session.state.value.draft)
        f.session.close()
    }

    @Test
    fun unknownQueriesWithoutResending() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("hello")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        f.peer.closed("Network lost")
        assertEquals(Delivery.UNKNOWN, f.session.state.value.delivery)
        f.session.retry()
        f.ready()
        f.subscribed()
        assertEquals(1, f.peer.sent.count { it.kind == "commandReceipt" })
        assertEquals(0, f.peer.sent.count { it.kind == "command" })
        assertFalse(f.session.state.value.canSend)
        f.session.close()
    }

    @Test
    fun takeoverNeverAutomaticallyReclaims() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.peer.receive(control("ended", obj("reason" to "takenOver")))
        f.session.foreground()
        advanceTimeBy(30_000)
        assertEquals(1, f.peers.size)
        assertEquals(Status.takenOver, f.session.state.value.status)
        f.session.retry()
        f.ready()
        assertEquals("ifFree", f.peer.sent.last().payload().string("intent"))
        f.session.close()
    }

    @Test
    fun oldCallbacksIgnoredAfterReconnect() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        val old = f.peer
        f.session.retry()
        f.ready()
        f.subscribed()
        f.frame()
        old.closed("late close")
        old.receive(Packet.Text(f.lease, 99, 80, 24, false, "stale"))
        assertEquals(Status.live, f.session.state.value.status)
        assertEquals("", f.session.state.value.text)
        f.session.close()
    }

    @Test
    fun busyStopsRetriesAndExplicitTakeoverWorks() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.peer.receive(control("failure", obj("error" to "PANE_BUSY: occupied")))
        assertEquals(Status.takenOver, f.session.state.value.status)
        advanceTimeBy(30_000)
        assertEquals(1, f.peers.size)
        f.session.takeOver()
        f.ready()
        assertEquals("takeover", f.peer.sent.last().payload().string("intent"))
        f.session.close()
    }

    @Test
    fun historyPageTimeoutCannotCancelNextPage() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.loadHistory()
        runCurrent()
        val history = uuid()
        advanceTimeBy(1_000)
        f.peer.receive(
            control(
                "historyPage",
                obj(
                    "subscriptionID" to f.lease,
                    "historyID" to history,
                    "offset" to 1,
                    "total" to 2,
                    "capturedAt" to 4.0,
                    "truncated" to false,
                    "lines" to listOf("b"),
                ),
            )
        )
        advanceTimeBy(6_000)
        f.session.loadHistory()
        runCurrent()
        advanceTimeBy(1_500)
        assertTrue(f.session.state.value.loadingHistory)
        f.peer.receive(
            control(
                "historyPage",
                obj(
                    "subscriptionID" to f.lease,
                    "historyID" to history,
                    "offset" to 0,
                    "total" to 2,
                    "capturedAt" to 4.0,
                    "truncated" to false,
                    "lines" to listOf("a"),
                ),
            )
        )
        assertEquals(listOf("a", "b"), f.session.state.value.history)
        f.session.retry()
        f.ready()
        f.subscribed()
        assertTrue(f.session.state.value.history.isEmpty())
        f.session.close()
    }

    @Test
    fun aLateHistoryPageAfterTheTimeoutIsShownWithoutDisconnecting() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.loadHistory()
        runCurrent()
        advanceTimeBy(8_001)
        runCurrent()
        assertFalse(f.session.state.value.loadingHistory)
        assertEquals(HISTORY_TIMED_OUT, f.session.state.value.error)
        f.session.loadHistory()
        assertTrue(f.session.state.value.loadingHistory)
        assertEquals(1, f.peer.sent.count { it.kind == "history" })
        advanceTimeBy(8_001)
        runCurrent()
        f.peer.receive(
            control(
                "historyPage",
                obj(
                    "subscriptionID" to f.lease, "historyID" to uuid(), "offset" to 0, "total" to 1,
                    "capturedAt" to 4.0, "truncated" to false, "lines" to listOf("late"),
                ),
            )
        )
        assertFalse(f.peer.stopped)
        assertEquals(Status.live, f.session.state.value.status)
        assertEquals(listOf("late"), f.session.state.value.history)
        assertNull(f.session.state.value.error)
        f.session.close()
    }
}
