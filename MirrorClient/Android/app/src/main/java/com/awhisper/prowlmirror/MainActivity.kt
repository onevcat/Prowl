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

    private val factory = TransportFactory { host, code, scope, receive, ready, closed ->
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
        )
    }

    fun add(host: Host, code: String) {
        val session = Session(host, viewModelScope, factory)
        sessions += session
        selected = session.id
        session.connect(code)
    }

    fun remove(session: Session) {
        session.close()
        sessions.remove(session)
        if (selected == session.id) selected = sessions.lastOrNull()?.id
    }

    fun foreground() {
        sessions.forEach(Session::foreground)
    }

    fun background() {
        sessions.forEach(Session::background)
    }

    override fun onCleared() {
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
