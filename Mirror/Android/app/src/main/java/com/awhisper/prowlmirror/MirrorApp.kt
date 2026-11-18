package com.awhisper.prowlmirror

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
fun MirrorApp(model: MirrorModel) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme(primary = Color(0xFF18A190))
        else lightColorScheme(primary = Color(0xFF0A7A72))
    ) {
        var add by remember { mutableStateOf(false) }
        var pairingSession by remember { mutableStateOf<String?>(null) }
        var manage by remember { mutableStateOf(false) }
        val session = model.sessions.firstOrNull { it.id == model.selected }
        val roster = model.roster
        val pane = session?.state?.collectAsState()?.value?.pane
        val rosterState = roster?.state?.collectAsState()?.value
        LaunchedEffect(roster, rosterState?.status) {
            if (roster != null && rosterState?.status == Status.choosing) {
                while (true) {
                    kotlinx.coroutines.delay(3_000)
                    roster.refreshPanes()
                }
            }
        }
        LaunchedEffect(session, rosterState?.panes) {
            rosterState?.panes?.firstOrNull { it.id == pane?.id }?.let { session?.updatePane(it) }
        }
        androidx.activity.compose.BackHandler(session != null) { model.closePane() }
        Surface(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                when {
                    session != null -> key(session.id) { Detail(session, model::closePane) }
                    roster != null && rosterState != null -> AgentsHome(
                        roster, rosterState, model.saved, model::openPane,
                        selectHost = { model.add(it, "") }, addHost = { add = true }, manageHosts = { manage = true },
                    )
                    else -> MirrorOnboarding { add = true }
                }
            }
        }
        val pairing = rosterState.takeIf { pairingSession != null && pairingSession == roster?.id }
        LaunchedEffect(pairing?.status) {
            if (pairing?.status == Status.choosing) {
                pairingSession = null
                add = false
            }
        }
        if (add) HostDialog(model.saved, pairing, { add = false; pairingSession = null }) { host, code ->
            model.add(host, code)
            pairingSession = model.roster?.id
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Detail(session: Session, back: () -> Unit) {
    val state by session.state.collectAsState()
    val pane = state.pane
    val agentState = if (state.chat) state.conversation.agentState ?: pane?.displayState else pane?.displayState
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val composing = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    val compact = LocalConfiguration.current.screenHeightDp < 500
    val hideKeyboard = { focus.clearFocus(); keyboard?.hide(); Unit }
    var menu by remember { mutableStateOf(false) }
    var confirmTakeover by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Column {
                    Text(pane?.tabTitle ?: pane?.title ?: "Prowl Mirror", maxLines = 1)
                    val subtitle = listOfNotNull(
                        agentState?.replaceFirstChar { it.uppercase() },
                        listOfNotNull(pane?.projectName, pane?.worktreeName).joinToString(" / ").ifBlank { null },
                    ).joinToString(" · ")
                    if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                }
            },
            navigationIcon = { IconButton(onClick = back) { Icon(Icons.Default.ArrowBack, "Agents") } },
            actions = {
                if (composing && compact) IconButton(onClick = hideKeyboard) {
                    Icon(Icons.Default.KeyboardHide, "Hide Keyboard")
                }
                if (pane?.conversation == "available" && "conversation-v1" in state.capabilities)
                    IconButton(onClick = { session.showChat(!state.chat) }) {
                        Icon(if (state.chat) Icons.Default.Terminal else Icons.Default.ChatBubbleOutline,
                            if (state.chat) "Terminal" else "Chat")
                    }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreHoriz, "Pane actions") }
                    DropdownMenu(menu, { menu = false }) {
                        if (!state.chat) DropdownMenuItem(
                            text = { Text(if (state.showsHistory) "Live Output" else "History") },
                            enabled = state.showsHistory || (state.status == Status.live && "history" in state.capabilities),
                            onClick = {
                                menu = false
                                if (state.showsHistory) session.showLive() else session.loadHistory(refresh = true)
                            },
                        )
                        if (state.status == Status.takenOver) DropdownMenuItem(
                            text = { Text("Take Over") }, onClick = { menu = false; confirmTakeover = true },
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
                if (state.status == Status.takenOver) TextButton(onClick = { confirmTakeover = true }) { Text("Take Over") }
            }
        }
        Box(Modifier.weight(1f)) {
            if (state.chat) ConversationReader(session, state.conversation) else Reading(session, state, hideLatest = composing && compact)
            if (composing && !compact) {
                Box(
                    Modifier.align(Alignment.BottomCenter).widthIn(max = if (state.chat) 720.dp else Dp.Unspecified)
                        .fillMaxWidth().padding(horizontal = 12.dp),
                ) {
                    FilledTonalIconButton(onClick = hideKeyboard, modifier = Modifier.align(Alignment.CenterStart)) {
                        Icon(Icons.Default.KeyboardHide, "Hide Keyboard")
                    }
                }
            }
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(Modifier.widthIn(max = if (state.chat) 720.dp else Dp.Unspecified).fillMaxWidth()) {
                MirrorActions(session, state)
                Composer(session, state)
            }
        }
    }
    if (confirmTakeover) AlertDialog(
        onDismissRequest = { confirmTakeover = false },
        title = { Text("Take over this pane?") },
        text = { Text("The other device will disconnect from this pane.") },
        confirmButton = { TextButton(onClick = { confirmTakeover = false; session.takeOver() }) { Text("Take Over") } },
        dismissButton = { TextButton(onClick = { confirmTakeover = false }) { Text("Cancel") } },
    )
}

@Composable
private fun HostDialog(
    saved: List<Host>,
    pairing: SessionState?,
    dismiss: () -> Unit,
    connect: (Host, String) -> Unit,
) {
    var chosen by remember { mutableStateOf<Host?>(null) }
    val connecting = pairing?.status == Status.connecting
    var address by remember { mutableStateOf(chosen?.address ?: "") }
    var port by remember { mutableStateOf((chosen?.port ?: DEFAULT_HOST_PORT).toString()) }
    var first by remember { mutableStateOf("") }
    var second by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Pair with a Mac") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (!connecting) PairingScanButton(connect = connect, failed = { error = it })
                saved.takeLast(5).reversed().forEach { host ->
                    TextButton(
                        onClick = {
                            chosen = host
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
                        { raw ->
                            val clean = raw.uppercase().filterNot { it.isWhitespace() || it == '-' }
                            first = clean.take(4)
                            // Only a complete pasted code may replace the other field.
                            if (clean.length >= 8) second = clean.drop(4).take(4)
                        },
                        label = { Text("Code") },
                        singleLine = true,
                        modifier = Modifier.weight(1f).testTag("code-first"),
                    )
                    Text(" – ")
                    OutlinedTextField(
                        second,
                        { second = it.uppercase().take(4) },
                        singleLine = true,
                        modifier = Modifier.weight(1f).testTag("code-second"),
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
                        val credential = if (raw.isBlank()) chosen?.credential else null
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

@Composable
private fun Reading(session: Session, state: SessionState, hideLatest: Boolean) {
    val source = if (state.showsHistory) state.history.joinToString("\n") else state.text
    val blocks = remember(source) { Document.blocks(source) }
    var detail by remember(session.id) { mutableStateOf<Block?>(null) }
    key(session.id, state.showsHistory) {
        val scroll =
            rememberLazyListState(
                if (state.showsHistory) session.historyScrollIndex else session.liveScrollIndex,
                if (state.showsHistory) session.historyScrollOffset else session.liveScrollOffset,
            )
        LaunchedEffect(scroll) {
            scroll.interactionSource.interactions.collect {
                if (it is DragInteraction.Start && !state.showsHistory) session.setFollow(false)
            }
        }
        LaunchedEffect(scroll) {
            snapshotFlow { scroll.firstVisibleItemIndex to scroll.firstVisibleItemScrollOffset }
                .collect { (index, offset) ->
                    if (state.showsHistory) {
                        session.historyScrollIndex = index
                        session.historyScrollOffset = offset
                    } else {
                        session.liveScrollIndex = index
                        session.liveScrollOffset = offset
                    }
                }
        }
        LaunchedEffect(state.sequence, state.follow, blocks.size) {
            if (state.follow && !state.showsHistory && blocks.isNotEmpty())
                scroll.scrollToItem(blocks.lastIndex)
        }
        LaunchedEffect(state.scrollCompletion) {
            val completion = state.scrollCompletion
            if (!state.showsHistory && completion != null && blocks.isNotEmpty()) {
                scroll.scrollToItem(0)
                session.consumeScrollCompletion(completion.requestID)
            }
        }
        Column(Modifier.fillMaxSize()) {
            if (state.showsHistory)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = session::showLive) { Text("Back to Live") }
                    TextButton(
                        onClick = { session.loadHistory() },
                        enabled = !state.loadingHistory && state.historyOffset > 0,
                    ) {
                        Text(if (state.loadingHistory) "Loading…" else "Load earlier")
                    }
                    if (state.historyTruncated)
                        Text("History truncated", style = MaterialTheme.typography.labelSmall)
                }
            else if ("remote-scroll" in state.capabilities)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = { session.scrollRemote(ScrollDirection.UP) },
                        enabled = state.canScrollRemote(ScrollDirection.UP),
                    ) { Text("Scroll up") }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        if (state.scrolling != null) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                Text("Loading…", modifier = Modifier.padding(start = 8.dp))
                            }
                        }
                    }
                    TextButton(
                        onClick = { session.scrollRemote(ScrollDirection.DOWN) },
                        enabled = state.canScrollRemote(ScrollDirection.DOWN),
                    ) { Text("Scroll down") }
                }
            Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                Modifier.fillMaxSize().testTag("mirror-output"),
                state = scroll,
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 56.dp),
            ) {
                itemsIndexed(blocks) { _, block ->
                    when (block) {
                        is Block.Text ->
                            SelectionContainer {
                                Text(
                                    inlineMarkdown(block.raw),
                                    modifier = Modifier.fillMaxWidth(),
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                            }
                        is Block.Code ->
                            OutlinedCard(
                                onClick = { detail = block },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            ) {
                                Text(
                                    block.language.ifBlank { "Code" } + " · Expand",
                                    style = MaterialTheme.typography.labelLarge,
                                    modifier = Modifier.padding(12.dp),
                                )
                                Text(
                                    block.raw.lines().take(6).joinToString("\n"),
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 6,
                                    modifier = Modifier.padding(12.dp),
                                )
                            }
                        is Block.Table ->
                            OutlinedCard(
                                onClick = { detail = block },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            ) {
                                Text(
                                    "Table · Expand",
                                    style = MaterialTheme.typography.labelLarge,
                                    modifier = Modifier.padding(12.dp),
                                )
                                Text(
                                    block.rows.take(4).joinToString("\n") {
                                        it.joinToString("  |  ")
                                    },
                                    maxLines = 5,
                                    modifier = Modifier.padding(12.dp),
                                )
                            }
                    }
                }
            }
                if (!state.showsHistory) {
                    if (state.truncated)
                        Text("Snapshot truncated", Modifier.align(Alignment.BottomStart).padding(12.dp),
                            style = MaterialTheme.typography.labelSmall)
                    if (!hideLatest && !state.follow && scroll.canScrollForward)
                        FilledTonalIconButton(
                            onClick = { session.setFollow(true) },
                            modifier = Modifier.align(Alignment.BottomEnd).padding(horizontal = 12.dp),
                        ) { Icon(Icons.Default.ArrowDownward, "Latest") }
                }
            }
        }
    }
    detail?.let { frozen ->
        val clipboard = LocalClipboardManager.current
        Dialog(
            onDismissRequest = { detail = null },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(Modifier.fillMaxSize().padding(20.dp), shape = MaterialTheme.shapes.large) {
                Column(Modifier.padding(16.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        TextButton(onClick = { detail = null }) { Text("Close") }
                        TextButton(onClick = { clipboard.setText(AnnotatedString(frozen.raw)) }) {
                            Text("Copy")
                        }
                    }
                    LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                        itemsIndexed(Document.chunks(frozen.raw)) { _, chunk ->
                            SelectionContainer { Text(chunk, fontFamily = FontFamily.Monospace) }
                        }
                    }
                }
            }
        }
    }
}

internal fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    // Plain text remains lossless when terminal output is not Markdown; no HTML or external
    // resources.
    val matches = Regex("\\*\\*(.+?)\\*\\*|`([^`\\n]+)`").findAll(text)
    var index = 0
    for (match in matches) {
        append(text.substring(index, match.range.first))
        val code = match.groups[2]?.value
        withStyle(
            if (code != null) SpanStyle(fontFamily = FontFamily.Monospace)
            else SpanStyle(fontWeight = FontWeight.Bold)
        ) {
            append(code ?: match.groupValues[1])
        }
        index = match.range.last + 1
    }
    append(text.substring(index))
}

@Composable
internal fun Composer(session: Session, state: SessionState) {
    var value by remember(session.id) { mutableStateOf(TextFieldValue(state.draft)) }
    var focused by remember { mutableStateOf(false) }
    val gesture = remember(session.id) { DoubleReturn() }
    val currentAgentState = if (state.chat) state.conversation.agentState ?: state.pane?.agentState else state.pane?.agentState
    val showStop = currentAgentState == "working" && state.pane?.agent != null &&
        state.keysAvailable && state.draft.isBlank() && state.delivery != Delivery.PENDING
    var stop by remember(session.id) { mutableStateOf(false) }
    LaunchedEffect(state.draft) {
        if (state.draft != value.text)
            value = TextFieldValue(state.draft, TextRange(state.draft.length))
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        state.hostDraft?.let { draft ->
            ElevatedCard(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text("There is a draft on the Mac", style = MaterialTheme.typography.titleSmall)
                    Text(draft.text, maxLines = 4)
                    if (draft.replaceable) {
                        TextButton(onClick = { session.replaceHostDraft(draft) }, enabled = state.canSend && value.composition == null) {
                            Text("Replace and Send")
                        }
                        if (draft.complete) TextButton(onClick = { session.bringHostDraft(draft) }, enabled = state.canAct && value.composition == null) {
                            Text("Bring Draft Here")
                        }
                    }
                    TextButton(onClick = session::dismissHostDraft) { Text("Cancel") }
                }
            }
        }
        if (state.hostDraft == null && state.delivery in setOf(Delivery.UNKNOWN, Delivery.REJECTED)) {
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
                Text(state.hint, Modifier.fillMaxWidth().padding(10.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            Spacer(Modifier.height(6.dp))
        }
        TextField(
            value,
            { next ->
                if (next.composition != null || !next.selection.collapsed) gesture.cancel()
                else gesture.validate(next.text, next.selection.start)
                value = next
                session.setDraft(next.text)
            },
            placeholder = { Text(if (state.pane?.agent == null) "Type a command" else "Message") },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
            colors = TextFieldDefaults.colors(
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
            ),
            trailingIcon = {
                IconButton(
                    enabled = if (showStop) state.canAct else state.canSend && value.composition == null,
                    onClick = {
                        gesture.cancel()
                        if (showStop) stop = true else session.submit()
                    },
                ) {
                    when {
                        state.delivery == Delivery.PENDING -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        showStop -> Icon(Icons.Default.Stop, "Stop")
                        else -> Icon(Icons.Default.ArrowUpward, "Send")
                    }
                }
            },
            minLines = 1,
            maxLines = if (focused) 6 else 1,
            modifier =
                Modifier.fillMaxWidth()
                    .testTag("composer")
                    .onFocusChanged {
                        focused = it.isFocused
                        if (!focused) gesture.cancel()
                    }
                    .onPreviewKeyEvent { event ->
                        val native = event.nativeKeyEvent
                        if (
                            native.keyCode == AndroidKeyEvent.KEYCODE_ENTER &&
                                native.action == AndroidKeyEvent.ACTION_UP
                        ) {
                            false
                        } else if (
                            native.keyCode == AndroidKeyEvent.KEYCODE_ENTER &&
                                native.repeatCount > 0
                        ) {
                            gesture.cancel()
                            false
                        } else if (
                            native.keyCode != AndroidKeyEvent.KEYCODE_ENTER ||
                                native.action != AndroidKeyEvent.ACTION_DOWN ||
                                native.deviceId == -1 ||
                                native.isShiftPressed ||
                                native.isCtrlPressed ||
                                native.isAltPressed ||
                                value.composition != null ||
                                !value.selection.collapsed
                        ) {
                            gesture.cancel()
                            false
                        } else {
                            val consumed =
                                gesture.consume(value.text, value.selection.start, native.eventTime)
                            if (consumed != null && state.canSend) {
                                value =
                                    TextFieldValue(
                                        consumed,
                                        TextRange((value.selection.start - 1).coerceAtLeast(0)),
                                    )
                                session.setDraft(consumed)
                                session.submit()
                                true
                            } else {
                                val cursor = value.selection.start
                                val text =
                                    value.text.substring(0, cursor) +
                                        "\n" +
                                        value.text.substring(cursor)
                                value = TextFieldValue(text, TextRange(cursor + 1))
                                session.setDraft(text)
                                gesture.record(text, cursor + 1, native.eventTime)
                                true
                            }
                        }
                    },
        )
        if (stop) AlertDialog(
            onDismissRequest = { stop = false },
            title = { Text("Stop this agent?") },
            confirmButton = { TextButton(onClick = { stop = false; session.sendKey("esc") }) { Text("Stop") } },
            dismissButton = { TextButton(onClick = { stop = false }) { Text("Cancel") } },
        )
        if (state.delivery == Delivery.UNKNOWN)
            Row {
                TextButton(onClick = session::queryReceipt) { Text("Check receipt") }
                var confirm by remember { mutableStateOf(false) }
                TextButton(onClick = { confirm = true }) { Text("I checked Host…") }
                if (confirm)
                    AlertDialog(
                        onDismissRequest = { confirm = false },
                        title = { Text("Allow another message?") },
                        text = {
                            Text(
                                "The previous message may have been delivered. Continue only after checking Host output; it will not be resent automatically."
                            )
                        },
                        confirmButton = {
                            TextButton(
                                onClick = {
                                    session.acknowledgeUnknown()
                                    confirm = false
                                }
                            ) {
                                Text("Continue")
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { confirm = false }) { Text("Cancel") }
                        },
                    )
            }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun LaunchDialog(session: Session, project: String? = null, dismiss: () -> Unit) {
    val model = session.launch
    val state by model.state.collectAsState()
    var worktrees by remember { mutableStateOf(false) }
    var profiles by remember { mutableStateOf(false) }
    val worktree = state.worktrees.firstOrNull { it.string("id") == state.worktree }
    val profile = state.profiles.firstOrNull { it.string("id") == state.profile }
    LaunchedEffect(model, project) { model.open(project) }
    LaunchedEffect(state.created) { if (state.created != null) dismiss() }
    ModalBottomSheet(onDismissRequest = { if (!state.creating) dismiss() }) {
        Column(
            Modifier.align(Alignment.CenterHorizontally).widthIn(max = 720.dp).fillMaxWidth()
                .verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
        ) {
            Text("New Session", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                state.prompt, model::setPrompt, placeholder = { Text("What would you like to work on?") },
                modifier = Modifier.fillMaxWidth(), maxLines = 6, enabled = !state.creating,
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                Box {
                    AssistChip(
                        onClick = { worktrees = true }, leadingIcon = { Icon(Icons.Default.Folder, null) },
                        label = { Text(worktree?.string("name") ?: "Project") },
                        enabled = state.worktrees.isNotEmpty() && !state.creating,
                    )
                    DropdownMenu(worktrees, { worktrees = false }) {
                        state.worktrees.forEach { tree ->
                            DropdownMenuItem(
                                text = { Text(tree.string("root_path").substringAfterLast('/') + " · " + tree.string("name")) },
                                onClick = { model.selectWorktree(tree.string("id")); worktrees = false },
                            )
                        }
                    }
                }
                Box {
                    AssistChip(
                        onClick = { profiles = true },
                        leadingIcon = { profile?.optionalString("runtime")?.let { AgentMark(it) } },
                        label = { Text(profile?.string("name") ?: "Agent Profile") },
                        enabled = state.profiles.isNotEmpty() && !state.creating,
                    )
                    DropdownMenu(profiles, { profiles = false }) {
                        state.profiles.forEach { entry ->
                            DropdownMenuItem(
                                text = {
                                    Column {
                                        Text(entry.string("name"))
                                        val detail = listOfNotNull(entry.optionalString("model"), entry.optionalString("reasoning_effort")).joinToString(" · ")
                                        if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall)
                                    }
                                },
                                leadingIcon = { entry.optionalString("runtime")?.let { AgentMark(it) } },
                                onClick = { model.selectProfile(entry.string("id")); profiles = false },
                            )
                        }
                    }
                }
            }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (state.uncertain) {
                TextButton(onClick = { session.refreshPanes(); dismiss() }) { Text("Review Host panes") }
                TextButton(onClick = model::acknowledgeUnknown) { Text("I checked Host; allow another creation") }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = dismiss, enabled = !state.creating) { Text("Cancel") }
                Button(onClick = model::create, enabled = state.canCreate) {
                    if (state.creating || state.loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Default.ArrowUpward, "Create session")
                }
            }
        }
    }
}
