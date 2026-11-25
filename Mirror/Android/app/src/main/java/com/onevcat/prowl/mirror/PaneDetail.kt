package com.onevcat.prowl.mirror

import androidx.compose.foundation.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.*
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun Detail(session: Session, back: () -> Unit) {
    val state by session.state.collectAsState()
    val pane = state.pane
    val kickoff = state.kickoff.takeUnless { state.chat || state.status !in setOf(Status.live, Status.connecting, Status.subscribing) }
    val showsChat = state.chat || kickoff != null
    LaunchedEffect(kickoff) {
        if (kickoff != null) {
            delay(10_000)
            session.stopWaitingForKickoff()
        }
    }
    val agentState = if (state.chat) state.conversation.agentState ?: pane?.displayState else pane?.displayState
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val composing = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    val compact = LocalConfiguration.current.screenHeightDp < 500
    val hideKeyboard = { focus.clearFocus(); keyboard?.hide(); Unit }
    var menu by remember { mutableStateOf(false) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val promptHeight = maxHeight / 2
        Column(Modifier.fillMaxSize()) {
            TopAppBar(
                title = {
                    if (!(composing && compact)) Column {
                        Text(pane?.tabTitle ?: pane?.title ?: "Prowl Mirror", maxLines = 1)
                        val subtitle = listOfNotNull(
                            agentState?.replaceFirstChar { it.uppercase() },
                            listOfNotNull(pane?.projectName, pane?.worktreeName).joinToString(" / ").ifBlank { null },
                        ).joinToString(" · ")
                        if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                    }
                },
                navigationIcon = { IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Agents") } },
                actions = {
                    if (composing && compact) IconButton(onClick = hideKeyboard) {
                        Icon(Icons.Default.KeyboardHide, "Hide Keyboard")
                    }
                    if (showsChat || (pane?.conversation != "unsupported" && "conversation-v1" in state.capabilities))
                        IconButton(onClick = {
                            if (kickoff != null) session.showTerminalAfterKickoff() else session.showChat(!state.chat)
                        }) {
                            Icon(if (showsChat) Icons.Default.Terminal else Icons.Default.ChatBubbleOutline,
                                if (showsChat) "Terminal" else "Chat")
                        }
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreHoriz, "Pane actions") }
                        DropdownMenu(menu, { menu = false }) {
                            if (!showsChat) DropdownMenuItem(
                                text = { Text(if (state.showsHistory) "Live Output" else "History") },
                                enabled = state.showsHistory || (state.status == Status.live && "history" in state.capabilities),
                                onClick = {
                                    menu = false
                                    if (state.showsHistory) session.showLive() else session.loadHistory(refresh = true)
                                },
                            )
                            if (state.status == Status.takenOver) DropdownMenuItem(
                                text = { Text("Take Over") }, onClick = { menu = false; session.takeOver() },
                            ) else if (state.status !in setOf(Status.live, Status.connecting, Status.subscribing))
                                DropdownMenuItem(text = { Text("Reconnect") }, onClick = { menu = false; session.retry() })
                            DropdownMenuItem(text = { Text("Disconnect") }, onClick = { menu = false; back() })
                        }
                    }
                },
            )
            if (state.status != Status.live || state.error != null) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(state.error ?: state.status.label, Modifier.weight(1f),
                        color = if (state.error == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error)
                    if (state.status == Status.takenOver) TextButton(onClick = session::takeOver) { Text("Take Over") }
                }
            }
            Box(Modifier.weight(1f)) {
                when {
                    state.chat -> ConversationReader(session, state.conversation, hideLatest = composing && compact)
                    kickoff != null -> StartingChat(kickoff)
                    else -> Reading(session, state, hideControls = composing && compact)
                }
                if (composing && !compact) {
                    Box(
                        Modifier.align(Alignment.BottomCenter).widthIn(max = if (showsChat) 720.dp else Dp.Unspecified)
                            .fillMaxWidth().padding(horizontal = 12.dp),
                    ) {
                        FilledTonalIconButton(onClick = hideKeyboard, modifier = Modifier.align(Alignment.CenterStart)) {
                            Icon(Icons.Default.KeyboardHide, "Hide Keyboard")
                        }
                    }
                }
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(Modifier.widthIn(max = if (showsChat) 720.dp else Dp.Unspecified).fillMaxWidth()) {
                    if (kickoff == null) MirrorActions(session, state, promptHeight, showKeys = !(composing && compact))
                    Composer(session, state)
                }
            }
        }
    }
}
