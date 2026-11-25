package com.awhisper.prowlmirror

import android.app.Application
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel

class MirrorViewModel(application: Application) : AndroidViewModel(application) {
    private val vault = Vault(application)
    val model = MirrorModel(viewModelScope, vault) { host, code, scope, receive, ready, closed, enrolled ->
        RemoteConnection(
            host,
            code,
            Build.MODEL.take(80),
            { vault.save(it.copy(pairedAt = System.currentTimeMillis()), replacingCredential = true) },
            scope,
            receive,
            ready,
            closed,
            onEnrolled = enrolled,
        )
    }

    override fun onCleared() = model.close()
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
            val vm: MirrorViewModel = viewModel()
            model = vm.model
            LaunchedEffect(vm) { vm.model.foreground() }
            MirrorApp(vm.model)
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
