package com.awhisper.prowlmirror

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MirrorModelTest {
    private class Store(vararg saved: Host) : HostStore {
        var entries = saved.toList()
        override fun hosts() = entries
        override fun save(host: Host, replacingCredential: Boolean) {
            mergeSavedHost(entries, host, replacingCredential)?.let { entries = it }
        }
        override fun rename(endpoint: String, name: String?) {
            entries = entries.map { if (it.endpoint == endpoint) it.copy(name = name) else it }
        }
        override fun forget(endpoint: String) {
            entries = entries.filterNot { it.endpoint == endpoint }
            if (selectedEndpoint == endpoint) selectedEndpoint = null
        }
        override var selectedEndpoint: String? = null
        override var lastProfile: String? = null
    }

    private class Peer(
        val host: Host,
        val code: String,
        val receive: (Packet) -> Unit,
        val ready: (Host) -> Unit,
    ) : Transport {
        val sent = mutableListOf<Packet.Control>()
        var stopped = false
        override fun send(message: Packet.Control) { sent += message }
        override fun close() { stopped = true }

        fun roster(vararg panes: Pane, name: String = "Studio") = receive(control("panes", obj(
            "panes" to panes.toList(), "capabilities" to listOf("text-v1", "launch-profile"),
            "hostRunID" to uuid(), "hostName" to name,
        )))
    }

    private class Fixture(scope: CoroutineScope, val store: Store) {
        val peers = mutableListOf<Peer>()
        val model = MirrorModel(scope, store) { host, code, _, receive, ready, _, _ ->
            Peer(host, code, receive, ready).also { peers += it }
        }
        fun peer(address: String) = peers.last { it.host.address == address }
    }

    private fun host(address: String, name: String? = null) =
        Host(address, credential = Credential(uuid(), uuid(), "key-$address"), name = name)

    @Test
    fun pairingSavesTheVerifiedHostAndMakesItTheRoster() = runTest {
        val f = Fixture(backgroundScope, Store())
        f.model.beginPairing(Host("studio.local"), "ABCD2345")
        val peer = f.peer("studio.local")
        assertEquals("ABCD2345", peer.code)
        assertNull(f.model.roster)
        val enrolled = host("studio.local")
        // RemoteConnection saves the enrollment before the connection is ready.
        f.store.save(enrolled, replacingCredential = true)
        peer.ready(enrolled)
        peer.roster()
        assertNull(f.model.pairing)
        assertSame(f.model.hostSession(enrolled), f.model.roster)
        assertEquals("studio.local:7880", f.store.selectedEndpoint)
        val saved = f.store.entries.single()
        assertEquals(enrolled.credential, saved.credential)
        assertEquals("Studio", saved.hostName)
        assertEquals(listOf(saved), f.model.saved)
        f.model.close()
    }

    @Test
    fun cancelledPairingClosesItsConnectionAndSavesNothing() = runTest {
        val f = Fixture(backgroundScope, Store())
        f.model.beginPairing(Host("studio.local"), "ABCD2345")
        f.model.cancelPairing()
        assertTrue(f.peer("studio.local").stopped)
        assertNull(f.model.pairing)
        assertTrue(f.store.entries.isEmpty())
        f.model.close()
    }

    @Test
    fun restorePrefersTheLastSelectedHost() = runTest {
        val first = host("a.local")
        val second = host("b.local")
        val store = Store(first, second).apply { selectedEndpoint = second.endpoint }
        val f = Fixture(backgroundScope, store)
        f.model.restoreHost()
        assertEquals(second.endpoint, f.model.roster?.state?.value?.host?.endpoint)
        f.model.close()
    }

    @Test
    fun selectingAHostWithANewCredentialReplacesItsRosterAndClosesThePane() = runTest {
        val original = host("a.local")
        val f = Fixture(backgroundScope, Store(original))
        f.model.selectHost(original)
        val oldRoster = f.peer("a.local")
        oldRoster.ready(original)
        val pane = Pane(uuid(), "Pane", "/tmp", false)
        oldRoster.roster(pane)
        f.model.openPane(pane)
        assertEquals(1, f.model.sessions.size)
        val paired = original.copy(credential = Credential(uuid(), uuid(), "new"))
        f.model.selectHost(paired)
        assertTrue(oldRoster.stopped)
        assertTrue(f.model.sessions.isEmpty())
        assertEquals(paired.credential, f.model.roster?.state?.value?.host?.credential)
        f.model.close()
    }

    @Test
    fun forgettingTheCurrentHostClosesItAndRestoresAnother() = runTest {
        val first = host("a.local")
        val second = host("b.local")
        val f = Fixture(backgroundScope, Store(first, second))
        f.model.selectHost(first)
        val forgotten = f.peer("a.local")
        f.model.forgetHost(first)
        assertTrue(forgotten.stopped)
        assertEquals(listOf(second), f.store.entries)
        assertEquals(second.endpoint, f.model.roster?.state?.value?.host?.endpoint)
        f.model.close()
    }

    @Test
    fun closingAPaneReleasesItOnTheRosterAndRefreshesIt() = runTest {
        val saved = host("a.local")
        val f = Fixture(backgroundScope, Store(saved))
        f.model.selectHost(saved)
        val roster = f.peer("a.local")
        roster.ready(saved)
        val pane = Pane(uuid(), "Pane", "/tmp", false)
        roster.roster(pane)
        f.model.openPane(pane)
        val mirror = f.peers.last()
        assertNotSame(roster, mirror)
        val lists = roster.sent.count { it.kind == "list" }
        f.model.closePane()
        assertTrue(mirror.stopped)
        assertNull(f.model.selected)
        assertEquals(lists + 1, roster.sent.count { it.kind == "list" })
        f.model.close()
    }

    @Test
    fun aStaleRosterCannotOverwriteANewerCredentialOrARename() {
        val original = host("a.local", name = "Alias")
        var saved = mergeSavedHost(emptyList(), original, replacingCredential = true)!!
        saved = saved.map { it.copy(name = null) }
        saved = mergeSavedHost(saved, original.copy(lastConnectedAt = 123L), replacingCredential = false)!!
        assertNull(saved.single().name)
        assertEquals(123L, saved.single().lastConnectedAt)
        val replacement = original.copy(credential = Credential(uuid(), uuid(), "replacement"), name = null)
        saved = mergeSavedHost(saved, replacement, replacingCredential = true)!!
        assertNull(mergeSavedHost(saved, original.copy(lastConnectedAt = 456L), replacingCredential = false))
        assertEquals(replacement.credential, saved.single().credential)
        assertEquals(123L, saved.single().lastConnectedAt)
    }
}
