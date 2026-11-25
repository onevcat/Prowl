package com.onevcat.prowl.mirror

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@Composable
fun MirrorApp(model: MirrorModel) {
    val colors = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Color(0xFF18A190),
        background = Color(0xFF121212), surface = Color(0xFF121212), surfaceVariant = Color(0xFF242426),
        secondaryContainer = Color(0xFF2C2C2E), onSecondaryContainer = Color(0xFFF2F2F7),
    ) else lightColorScheme(
        primary = Color(0xFF0A7A72),
        background = Color.White, surface = Color.White, surfaceVariant = Color(0xFFF2F2F7),
        secondaryContainer = Color(0xFFF2F2F7), onSecondaryContainer = Color(0xFF1C1C1E),
    )
    MaterialTheme(colorScheme = colors) {
        var add by rememberSaveable { mutableStateOf(false) }
        var pairingRequested by rememberSaveable { mutableStateOf(false) }
        var manage by rememberSaveable { mutableStateOf(false) }
        val session = model.sessions.firstOrNull { it.id == model.selected }
        val roster = model.roster
        val pane = session?.state?.collectAsState()?.value?.pane
        val rosterState = roster?.state?.collectAsState()?.value
        val waitingForChat = session?.state?.collectAsState()?.value?.kickoff != null
        LaunchedEffect(roster, rosterState?.status, waitingForChat) {
            if (waitingForChat && roster != null && rosterState?.status == Status.choosing) {
                while (true) {
                    delay(1_000)
                    roster.refreshPanes()
                }
            }
        }
        LaunchedEffect(session, rosterState?.panes) {
            rosterState?.panes?.firstOrNull { it.id == pane?.id }?.let { session?.updatePane(it) }
        }
        androidx.activity.compose.BackHandler(session != null || model.isDemo) {
            if (session != null) model.closePane() else model.exitDemo()
        }
        Surface(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                when {
                    session != null -> key(session.id) { Detail(session, model::closePane) }
                    roster != null && rosterState != null -> AgentsHome(
                        roster, rosterState, if (model.isDemo) emptyList() else model.saved, model::openPane,
                        selectHost = model::selectHost, addHost = { add = true }, manageHosts = { manage = true },
                        demo = model.isDemo, exitDemo = model::exitDemo,
                    )
                    else -> MirrorOnboarding(pair = { add = true }, demo = model::startDemo)
                }
            }
        }
        val pairing = model.pairing?.state?.collectAsState()?.value
        LaunchedEffect(pairingRequested, model.pairing) {
            if (pairingRequested && model.pairing == null) {
                pairingRequested = false
                add = false
            }
        }
        if (add) HostDialog(model.saved, pairing, {
            pairingRequested = false
            add = false
            model.cancelPairing()
        }) { host, code ->
            model.beginPairing(host, code)
            pairingRequested = true
        }
        if (manage) ManageHosts(model, { manage = false }) {
            manage = false
            add = true
        }
        model.error?.let { message ->
            AlertDialog(
                onDismissRequest = { model.error = null },
                title = { Text("Saved Hosts") },
                text = { Text(message) },
                confirmButton = { TextButton(onClick = { model.error = null }) { Text("OK") } },
            )
        }
    }
}


@Composable
private fun HostDialog(
    saved: List<Host>,
    pairing: SessionState?,
    dismiss: () -> Unit,
    connect: (Host, String) -> Unit,
) {
    val connecting = pairing?.status == Status.connecting
    var address by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf(DEFAULT_HOST_PORT.toString()) }
    var first by rememberSaveable { mutableStateOf("") }
    var second by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    val secondFocus = remember { FocusRequester() }
    val codeKeyboard = KeyboardOptions(
        capitalization = KeyboardCapitalization.Characters, autoCorrect = false, keyboardType = KeyboardType.Ascii,
    )
    fun setCode(raw: String, firstField: Boolean) {
        error = null
        val clean = raw.uppercase().filterNot { it.isWhitespace() || it == '-' }
        if (clean.length == 8) {
            first = clean.take(4)
            second = clean.drop(4)
        } else if (firstField) {
            val filled = first.length < 4 && clean.length == 4 && second.isEmpty()
            first = clean.take(4)
            if (filled) secondFocus.requestFocus()
        } else {
            second = clean.take(4)
        }
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Pair with a Mac") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (!connecting) PairingScanButton(
                    connect = { host, code ->
                        error = null
                        address = host.address
                        port = host.port.toString()
                        setCode(code, firstField = true)
                        connect(host, code)
                    },
                    failed = { error = it },
                )
                saved.take(5).forEach { host ->
                    TextButton(
                        onClick = {
                            address = host.address
                            port = host.port.toString()
                            first = ""
                            second = ""
                        }
                    ) {
                        Text(host.endpoint)
                    }
                }
                OutlinedTextField(
                    address,
                    { address = it },
                    label = { Text("IP address or hostname") },
                    singleLine = true,
                    modifier = Modifier.testTag("host-address"),
                )
                OutlinedTextField(port, { port = it }, label = { Text("Port") }, singleLine = true)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        first,
                        { setCode(it, firstField = true) },
                        label = { Text("Code") },
                        singleLine = true,
                        modifier = Modifier.weight(1f).testTag("code-first"),
                        keyboardOptions = codeKeyboard,
                    )
                    Text(" – ")
                    OutlinedTextField(
                        second,
                        { setCode(it, firstField = false) },
                        singleLine = true,
                        modifier = Modifier.weight(1f).focusRequester(secondFocus).testTag("code-second"),
                        keyboardOptions = codeKeyboard,
                    )
                }
                Text(
                    "Open Add a Device on Host. Leave code blank for a saved device.",
                    style = MaterialTheme.typography.bodySmall,
                )
                (error ?: pairing?.error)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !connecting,
                onClick = {
                    error = null
                    try {
                        val hostAddress = address.trim()
                        val hostPort = port.toIntOrNull()
                        require(
                            hostAddress.isNotEmpty() &&
                                hostAddress.none { it.isWhitespace() || it == '/' } &&
                                hostPort != null &&
                                hostPort in 1..65535
                        ) {
                            "Enter a Host address and valid port"
                        }
                        val raw = first + second
                        val credential = if (raw.isBlank())
                            saved.firstOrNull { it.address == hostAddress && it.port == hostPort }?.credential
                        else null
                        val code = if (credential != null) "" else Authentication.code(raw)
                        connect(Host(hostAddress, hostPort, credential), code)
                    } catch (e: Exception) {
                        error = e.message
                    }
                }
            ) {
                if (connecting) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else Text("Connect")
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
    )
}
