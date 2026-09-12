package com.awhisper.prowlmirror

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.DragInteraction
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MirrorApp(model: MirrorModel) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
    ) {
        var add by remember { mutableStateOf(false) }
        val drawer = rememberDrawerState(DrawerValue.Closed)
        val scope = rememberCoroutineScope()
        val session = model.sessions.firstOrNull { it.id == model.selected }
        Surface(Modifier.fillMaxSize()) {
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                val wide = maxWidth >= 840.dp
                val sidebar: @Composable () -> Unit = {
                    Sidebar(model, { add = true }) {
                        model.selected = it
                        scope.launch { drawer.close() }
                    }
                }
                if (wide)
                    Row {
                        Surface(
                            Modifier.width(300.dp).fillMaxHeight(),
                            color = MaterialTheme.colorScheme.surfaceVariant,
                        ) {
                            sidebar()
                        }
                        Box(Modifier.weight(1f)) {
                            Detail(
                                session,
                                { scope.launch { drawer.open() } },
                                { add = true },
                                false,
                            )
                        }
                    }
                else
                    ModalNavigationDrawer(
                        drawerState = drawer,
                        drawerContent = { ModalDrawerSheet(Modifier.width(300.dp)) { sidebar() } },
                    ) {
                        Detail(session, { scope.launch { drawer.open() } }, { add = true }, true)
                    }
            }
        }
        if (add)
            HostDialog(model.saved, null, { add = false }) { host, code ->
                model.add(host, code)
                add = false
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
private fun Sidebar(model: MirrorModel, add: () -> Unit, select: (String) -> Unit) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Prowl Mirror",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = add) { Icon(Icons.Default.Add, "Add Host") }
        }
        Text(
            "Remote panes",
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(vertical = 20.dp),
        )
        LazyColumn {
            itemsIndexed(model.sessions, key = { _, item -> item.id }) { _, session ->
                val state by session.state.collectAsState()
                Surface(
                    onClick = { select(session.id) },
                    shape = MaterialTheme.shapes.medium,
                    color =
                        if (model.selected == session.id)
                            MaterialTheme.colorScheme.secondaryContainer
                        else MaterialTheme.colorScheme.surface,
                ) {
                    Row(
                        Modifier.padding(start = 12.dp, top = 12.dp, bottom = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                state.pane?.label ?: state.host.address,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 2,
                            )
                            Text(
                                state.pane?.subtitle ?: state.host.endpoint,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 2,
                            )
                            Text(
                                state.status.label,
                                style = MaterialTheme.typography.labelSmall,
                                color = statusColor(state.status),
                            )
                        }
                        IconButton(onClick = { model.remove(session) }) {
                            Icon(Icons.Default.Close, "Close mirror")
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun statusColor(status: Status) =
    when (status) {
        Status.live -> Color(0xFF239B56)
        Status.connecting,
        Status.choosing,
        Status.subscribing -> MaterialTheme.colorScheme.onSurfaceVariant
        else -> MaterialTheme.colorScheme.error
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Detail(session: Session?, menu: () -> Unit, add: () -> Unit, compact: Boolean) {
    var edit by remember(session?.id) { mutableStateOf(false) }
    var launch by remember(session?.id) { mutableStateOf(false) }
    val state = session?.state?.collectAsState()?.value
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(state?.pane?.label ?: "Prowl Mirror", maxLines = 1) },
            navigationIcon = {
                if (compact) IconButton(onClick = menu) { Icon(Icons.Default.Menu, "Open sidebar") }
            },
            actions = {
                if (state?.status == Status.live)
                    IconButton(onClick = { session.loadHistory(refresh = true) }) {
                        Icon(Icons.Default.History, "History")
                    }
                if (session != null)
                    IconButton(onClick = { edit = true }) {
                        Icon(Icons.Default.Settings, "Edit Host")
                    }
                IconButton(onClick = add) { Icon(Icons.Default.Add, "Add remote pane") }
            },
        )
        if (session == null || state == null) {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(Icons.Default.Public, null, Modifier.size(54.dp))
                Spacer(Modifier.height(20.dp))
                Text("Connect to Prowl", style = MaterialTheme.typography.headlineSmall)
                Text("Choose an open pane on your Mac.", modifier = Modifier.padding(16.dp))
                Button(onClick = add) { Text("Add Remote Pane") }
            }
        } else {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    state.status.label,
                    color = statusColor(state.status),
                    modifier = Modifier.weight(1f),
                )
                if (
                    state.status in
                        setOf(
                            Status.disconnected,
                            Status.hostStopped,
                            Status.paneClosed,
                            Status.takenOver,
                        )
                )
                    TextButton(onClick = session::retry) { Text("Retry") }
                if (state.status == Status.takenOver)
                    TextButton(onClick = session::takeOver) { Text("Take Over") }
            }
            state.error?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(16.dp),
                )
            }
            if (state.status == Status.choosing || state.status == Status.paneClosed) {
                LazyColumn(Modifier.weight(1f).padding(16.dp)) {
                    item {
                        Text("Select a Host pane", style = MaterialTheme.typography.titleLarge)
                        Spacer(Modifier.height(16.dp))
                    }
                    itemsIndexed(state.panes) { _, pane ->
                        ListItem(
                            headlineContent = { Text(pane.label) },
                            supportingContent = { Text(pane.subtitle ?: pane.directory) },
                            trailingContent = {
                                TextButton(onClick = { session.choose(pane, takeover = pane.busy) }) {
                                    Text(if (pane.busy) "Take over" else "Mirror")
                                }
                            },
                        )
                        HorizontalDivider()
                    }
                    item {
                        TextButton(onClick = session::refreshPanes) { Text("Refresh Panes") }
                        if (
                            "launch-profile" in state.capabilities &&
                                state.status == Status.choosing
                        )
                            Button(onClick = { launch = true }) { Text("New Agent Pane") }
                        if (state.panes.isEmpty())
                            Text("No running panes. Open one on Host or create an Agent pane.")
                    }
                }
            } else {
                Box(Modifier.weight(1f)) { Reading(session, state) }
                Composer(session, state)
            }
        }
    }
    if (edit && session != null && state != null)
        HostDialog(emptyList(), state.host, { edit = false }) { host, code ->
            session.editHost(host, code)
            edit = false
        }
    if (launch && session != null) LaunchDialog(session) { launch = false }
}

@Composable
private fun HostDialog(
    saved: List<Host>,
    initial: Host?,
    dismiss: () -> Unit,
    connect: (Host, String) -> Unit,
) {
    var chosen by remember { mutableStateOf(initial ?: saved.lastOrNull()) }
    var address by remember { mutableStateOf(chosen?.address ?: "") }
    var port by remember { mutableStateOf((chosen?.port ?: DEFAULT_HOST_PORT).toString()) }
    var first by remember { mutableStateOf("") }
    var second by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Remote Mirror Host") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
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
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
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
                Text("Connect")
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
    )
}

@Composable
private fun Reading(session: Session, state: SessionState) {
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
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth().testTag("mirror-output"),
                state = scroll,
                contentPadding = PaddingValues(16.dp),
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
            if (!state.showsHistory)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    if (state.truncated)
                        Text("Snapshot truncated", style = MaterialTheme.typography.labelSmall)
                    TextButton(onClick = { session.setFollow(true) }) {
                        Text(if (state.follow) "Following latest" else "Follow latest")
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

private fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
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
    LaunchedEffect(state.draft) {
        if (state.draft != value.text)
            value = TextFieldValue(state.draft, TextRange(state.draft.length))
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        OutlinedTextField(
            value,
            { next ->
                if (next.composition != null || !next.selection.collapsed) gesture.cancel()
                else gesture.validate(next.text, next.selection.start)
                value = next
                session.setDraft(next.text)
            },
            placeholder = { Text("Message Host…") },
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
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                state.hint,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color =
                    if (state.delivery in setOf(Delivery.UNKNOWN, Delivery.REJECTED))
                        MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = {
                    gesture.cancel()
                    session.submit()
                },
                enabled = state.canSend && value.composition == null,
            ) {
                Text("Send")
            }
        }
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

@Composable
private fun LaunchDialog(session: Session, dismiss: () -> Unit) {
    val model = session.launch
    val state by model.state.collectAsState()
    LaunchedEffect(model) { model.open() }
    LaunchedEffect(state.created) { if (state.created != null) dismiss() }
    AlertDialog(
        onDismissRequest = { if (!state.creating) dismiss() },
        title = { Text("New Agent Pane") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (state.loading) CircularProgressIndicator()
                Text("Workspace")
                state.worktrees.forEach { item ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(
                            selected = state.worktree == item.string("id"),
                            onClick = { model.selectWorktree(item.string("id")) },
                            enabled = !state.creating,
                        )
                        Text(
                            item.string("root_path").substringAfterLast('/') +
                                " · " +
                                item.string("name")
                        )
                    }
                }
                Text("Agent Profile")
                state.profiles.forEach { item ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(
                            selected = state.profile == item.string("id"),
                            onClick = { model.selectProfile(item.string("id")) },
                            enabled = !state.creating,
                        )
                        Text(item.string("name"))
                    }
                }
                if (!state.loading && state.profiles.isEmpty())
                    Text("Configure an available Agent Profile on Host first.")
                OutlinedTextField(
                    state.prompt,
                    model::setPrompt,
                    label = { Text("Initial message (optional)") },
                    maxLines = 6,
                    enabled = !state.creating,
                )
                Text(
                    "Model and permissions come from the Host Profile.",
                    style = MaterialTheme.typography.bodySmall,
                )
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (state.uncertain) {
                    TextButton(
                        onClick = {
                            session.refreshPanes()
                            dismiss()
                        }
                    ) {
                        Text("Review Host panes")
                    }
                    TextButton(onClick = model::acknowledgeUnknown) {
                        Text("I checked Host; allow another creation")
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = state.canCreate, onClick = model::create) {
                Text(if (state.creating) "Creating…" else "Create")
            }
        },
        dismissButton = {
            TextButton(onClick = dismiss, enabled = !state.creating) { Text("Cancel") }
        },
    )
}
