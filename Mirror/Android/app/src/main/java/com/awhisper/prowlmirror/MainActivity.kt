package com.awhisper.prowlmirror

import android.app.Application
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel

class MirrorModel(application: Application) : AndroidViewModel(application) {
    val vault = Vault(application)
    val sessions = mutableStateListOf<Session>()
    var selected by mutableStateOf<String?>(null)
    var saved by mutableStateOf<List<Host>>(emptyList())
    var roster by mutableStateOf<Session?>(null)
        private set
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

    private val factory = TransportFactory { host, code, scope, receive, ready, closed, enrolled ->
        RemoteConnection(
            host,
            code,
            Build.MODEL.take(80),
            vault::save,
            scope,
            receive,
            { verified ->
                reloadHosts()
                ready(verified)
            },
            closed,
            onEnrolled = { saved ->
                reloadHosts()
                enrolled(saved)
            },
        )
    }

    fun restoreHost() {
        if (roster != null || sessions.isNotEmpty()) return
        val last = saved.firstOrNull { it.endpoint == vault.selectedEndpoint } ?: saved.lastOrNull()
        if (last != null) add(last, "")
    }

    fun startDemo() {
        if (roster != null) return
        val host = DemoHost(viewModelScope)
        demo = host
        roster = Session(host.address, viewModelScope, host.transport, onLaunch = ::openLaunchedPane)
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

    fun add(host: Host, code: String) {
        closePane()
        roster?.close()
        val session = Session(
            host, viewModelScope, factory, onLaunch = ::openLaunchedPane,
            loadProfile = { vault.lastProfile }, saveProfile = { vault.lastProfile = it },
        )
        roster = session
        vault.selectedEndpoint = host.endpoint
        session.connect(code)
    }

    fun openPane(pane: Pane) = openLaunchedPane(pane, null)

    private fun openLaunchedPane(pane: Pane, kickoff: String?) {
        val host = roster?.state?.value?.host ?: return
        if (host.credential == null && demo == null) return
        closePane()
        val session = Session(host, viewModelScope, demo?.transport ?: factory)
        sessions += session
        selected = session.id
        session.choose(pane, kickoff = kickoff)
        session.connect()
    }

    fun closePane() {
        sessions.forEach(Session::close)
        sessions.clear()
        selected = null
        roster?.refreshPanes()
    }

    fun renameHost(host: Host, name: String) {
        updateVault { vault.save(host.copy(name = name.trim().ifBlank { null })) }
    }

    fun forgetHost(host: Host) {
        updateVault {
            vault.forget(host.endpoint)
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
        roster?.foreground()
        sessions.forEach(Session::foreground)
    }

    fun background() {
        roster?.background()
        sessions.forEach(Session::background)
    }

    override fun onCleared() {
        roster?.close()
        sessions.forEach(Session::close)
    }
}

class MainActivity : ComponentActivity() {
    private var model: MirrorModel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        setContent {
            val vm: MirrorModel = viewModel()
            model = vm
            LaunchedEffect(vm) { vm.foreground() }
            MirrorApp(vm)
        }
    }

    override fun onStart() {
        super.onStart()
        model?.foreground()
    }

    override fun onStop() {
        model?.background()
        super.onStop()
    }
}
