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
        val pane = Pane(uuid(), "Pane", "/tmp", false)
        val run = uuid()
        val lease = uuid()
        val session =
            Session(
                host,
                scope,
                TransportFactory { _, _, _, receive, ready, close ->
                    Peer(receive, ready, close).also { peers += it }
                },
            )
        val peer
            get() = peers.last()

        fun ready() {
            peer.ready(host)
            peer.receive(
                control(
                    "panes",
                    obj(
                        "panes" to listOf(pane),
                        "capabilities" to listOf("text-v1", "launch-profile", "history", "refresh"),
                        "hostRunID" to run,
                    ),
                )
            )
        }

        fun live() {
            session.connect()
            ready()
            session.choose(pane)
            subscribed()
        }

        fun subscribed() {
            peer.receive(
                control(
                    "subscribed",
                    obj("paneID" to pane.id, "subscriptionID" to lease, "hostRunID" to run),
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

        fun listing() {
            val id = peer.sent.last().payload().record("commandRequest").string("requestID")
            answer(
                id,
                obj(
                    "ok" to true,
                    "data" to
                        obj(
                            "items" to
                                listOf(
                                    obj(
                                        "pane" to obj("id" to pane.id, "agent" to "codex"),
                                        "task" to obj("status" to "idle"),
                                    )
                                )
                        ),
                ),
            )
        }
    }

    @Test
    fun replacementAckAndStaleLease() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.peer.receive(Packet.Text(f.lease, 1, 80, 24, false, "old"))
        f.peer.receive(Packet.Text(f.lease, 2, 80, 24, false, ""))
        assertEquals("", f.session.state.value.text)
        assertEquals("acknowledge", f.peer.sent.last().kind)
        f.peer.receive(Packet.Text(uuid(), 3, 80, 24, false, "wrong"))
        assertEquals(Status.disconnected, f.session.state.value.status)
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
        f.answer(id, obj("ok" to true, "data" to obj("dispatch" to obj("id" to "accepted"))))
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
    fun rejectedHostEditKeepsOriginalConnectionAndDraft() = runTest {
        val f = Fixture(backgroundScope)
        f.live()
        f.session.setDraft("hello")
        f.session.submit()
        runCurrent()
        f.listing()
        runCurrent()
        f.session.editHost(Host("different"), "ABCD2345")
        assertFalse(f.peer.stopped)
        assertEquals(Status.live, f.session.state.value.status)
        assertEquals("hello", f.session.state.value.draft)
        assertEquals(Delivery.PENDING, f.session.state.value.delivery)
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
}
