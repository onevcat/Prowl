package com.awhisper.prowlmirror

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope

/** Saved Hosts, their roster connections and the open pane. The Activity's view model owns it. */
class MirrorModel(
    private val scope: CoroutineScope,
    private val vault: HostStore,
    private val factory: TransportFactory,
) {
    val sessions = mutableStateListOf<Session>()
    var selected by mutableStateOf<String?>(null)
    var saved by mutableStateOf<List<Host>>(emptyList())
    var roster by mutableStateOf<Session?>(null)
        private set
    var pairing by mutableStateOf<Session?>(null)
        private set
    private val rosters = mutableStateMapOf<String, Session>()
    private var demo by mutableStateOf<DemoHost?>(null)
    val isDemo: Boolean get() = demo != null
    var error by mutableStateOf<String?>(null)

    init {
        reloadHosts()
    }

    fun reloadHosts() {
        try {
            saved = vault.hosts()
        } catch (e: Exception) {
            error = "Cannot read saved credentials: ${e.message}"
        }
    }

    fun restoreHost() {
        if (roster != null || sessions.isNotEmpty()) return
        val last = saved.firstOrNull { it.endpoint == vault.selectedEndpoint } ?: saved.firstOrNull()
        if (last != null) selectHost(last)
    }

    fun startDemo() {
        if (roster != null) return
        val host = DemoHost(scope)
        demo = host
        roster = Session(host.address, scope, host.transport, onLaunch = ::openLaunchedPane, localDemo = true)
            .also { it.connect() }
    }

    fun exitDemo() {
        val host = demo ?: return
        host.close()
        sessions.forEach(Session::close)
        sessions.clear()
        selected = null
        roster?.close()
        roster = null
        demo = null
    }

    private fun newRoster(host: Host, onRoster: (Session, Host) -> Unit) = Session(
        host, scope, factory, onLaunch = ::openLaunchedPane,
        loadProfile = { vault.lastProfile }, saveProfile = { vault.lastProfile = it },
        onRoster = onRoster,
    )

    private fun rememberVerifiedHost(host: Host) = updateVault { vault.save(host, replacingCredential = false) }

    internal fun hostSession(host: Host) = rosters[host.endpoint]

    fun selectHost(host: Host) {
        val cached = rosters[host.endpoint]
        if (roster !== cached || cached?.state?.value?.host?.credential != host.credential) closePane()
        if (cached != null && cached.state.value.host.credential != host.credential) {
            rosters.remove(host.endpoint)
            cached.close()
        }
        val session = rosters.getOrPut(host.endpoint) { newRoster(host) { _, verified -> rememberVerifiedHost(verified) } }
        roster = session
        vault.selectedEndpoint = host.endpoint
        session.foreground()
    }

    fun beginPairing(host: Host, code: String) {
        cancelPairing()
        val candidate = newRoster(host) { session, verified ->
            if (pairing === session) {
                try {
                    vault.save(verified, replacingCredential = false)
                    reloadHosts()
                    closePane()
                    rosters.put(verified.endpoint, session)?.close()
                    roster = session
                    vault.selectedEndpoint = verified.endpoint
                    pairing = null
                } catch (e: Exception) {
                    session.close()
                    pairing = null
                    error = e.message
                }
            } else if (rosters[verified.endpoint] === session) rememberVerifiedHost(verified)
        }
        pairing = candidate
        candidate.connect(code)
    }

    fun cancelPairing() {
        pairing?.close()
        pairing = null
        reloadHosts()
    }

    fun openPane(pane: Pane) = openPane(pane, null, launched = false)

    private fun openLaunchedPane(pane: Pane, kickoff: String?) = openPane(pane, kickoff, launched = true)

    private fun openPane(pane: Pane, kickoff: String?, launched: Boolean) {
        val host = roster?.state?.value?.host ?: return
        if (host.credential == null && demo == null) return
        closePane()
        val session = Session(host, scope, demo?.transport ?: factory, localDemo = demo != null)
        sessions += session
        selected = session.id
        session.choose(pane, takeover = pane.busy, kickoff = kickoff, launched = launched)
        session.connect()
    }

    fun closePane() {
        val released = sessions.mapNotNull(Session::leasedPaneID)
        sessions.forEach(Session::close)
        sessions.clear()
        selected = null
        roster?.let { session ->
            released.forEach(session::releasePane)
            session.refreshPanes()
        }
    }

    fun renameHost(host: Host, name: String) {
        updateVault { vault.rename(host.endpoint, name.trim().ifBlank { null }) }
    }

    fun forgetHost(host: Host) {
        updateVault {
            vault.forget(host.endpoint)
            rosters.remove(host.endpoint)?.close()
            if (roster?.state?.value?.host?.endpoint == host.endpoint) {
                closePane()
                roster?.close()
                roster = null
            }
        }
        restoreHost()
    }

    private fun updateVault(action: () -> Unit) {
        try {
            action()
            reloadHosts()
        } catch (e: Exception) {
            error = e.message ?: "Could not update saved Hosts"
        }
    }

    fun foreground() {
        restoreHost()
        (rosters.values + listOfNotNull(roster)).distinct().forEach(Session::foreground)
        sessions.forEach(Session::foreground)
    }

    fun background() {
        (rosters.values + listOfNotNull(roster)).distinct().forEach(Session::background)
        sessions.forEach(Session::background)
    }

    fun close() {
        cancelPairing()
        demo?.close()
        (rosters.values + listOfNotNull(roster)).distinct().forEach(Session::close)
        sessions.forEach(Session::close)
    }
}
