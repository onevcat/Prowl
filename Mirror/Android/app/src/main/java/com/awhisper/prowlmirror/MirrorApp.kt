package com.awhisper.prowlmirror

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Detail(session: Session, back: () -> Unit) {
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

@Composable
private fun Reading(session: Session, state: SessionState, hideControls: Boolean) {
    if (state.showsHistory) {
        HistoryReader(session, state)
        return
    }
    val blocks = remember(state.text) { Document.blocks(state.text) }
    var detail by remember(session.id) { mutableStateOf<Block?>(null) }
    key(session.id) {
        val scroll = rememberLazyListState(session.liveScrollIndex, session.liveScrollOffset)
        var userReleased by remember { mutableStateOf(false) }
        LaunchedEffect(scroll) {
            scroll.interactionSource.interactions.collect {
                when (it) {
                    is DragInteraction.Start -> {
                        userReleased = false
                        session.setFollow(false)
                    }
                    is DragInteraction.Stop -> userReleased = true
                    is DragInteraction.Cancel -> userReleased = false
                }
            }
        }
        LaunchedEffect(scroll) {
            snapshotFlow { userReleased && !scroll.isScrollInProgress }.collect { settled ->
                if (settled) {
                    withFrameNanos { }
                    val current = session.state.value
                    if (!scroll.isScrollInProgress && current.scrolling == null && current.scrollCompletion == null) {
                        session.setFollow(!scroll.canScrollForward)
                        userReleased = false
                    }
                }
            }
        }
        LaunchedEffect(scroll) {
            snapshotFlow { scroll.firstVisibleItemIndex to scroll.firstVisibleItemScrollOffset }
                .collect { (index, offset) ->
                    session.liveScrollIndex = index
                    session.liveScrollOffset = offset
                }
        }
        val viewportHeight by remember(scroll) { derivedStateOf { scroll.layoutInfo.viewportSize.height } }
        LaunchedEffect(state.sequence, state.follow, blocks.size, viewportHeight) {
            if (state.follow && blocks.isNotEmpty()) scroll.revealEnd(blocks.lastIndex)
        }
        LaunchedEffect(state.scrollCompletion) {
            val completion = state.scrollCompletion
            if (completion != null) {
                userReleased = false
                if (blocks.isNotEmpty()) scroll.scrollToItem(0)
                session.consumeScrollCompletion(completion.requestID)
            }
        }
        Box(Modifier.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize().testTag("mirror-output"),
                state = scroll,
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 56.dp),
            ) {
                itemsIndexed(blocks) { index, block ->
                    when (block) {
                        is Block.Text -> Column {
                            val clipboard = LocalClipboardManager.current
                            if (block.whole != null && (blocks.getOrNull(index - 1) as? Block.Text)?.whole !== block.whole)
                                TextButton(onClick = { clipboard.setText(AnnotatedString(block.whole)) }) {
                                    Text("Copy Full Text Block")
                                }
                            SelectionContainer {
                                Text(
                                    if (block.whole != null) AnnotatedString(block.raw) else inlineMarkdown(block.raw),
                                    modifier = Modifier.fillMaxWidth(),
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                            }
                        }
                        is Block.Code -> ReadingPreview(
                            block.language.ifBlank { "Code" },
                            open = { detail = block },
                        ) {
                            SelectionContainer {
                                Text(block.raw, fontFamily = FontFamily.Monospace, maxLines = 6)
                            }
                        }
                        is Block.Table -> ReadingPreview(
                            "Table · ${(block.rows.size - 1).coerceAtLeast(0)} rows",
                            open = { detail = block },
                        ) {
                            Column(Modifier.horizontalScroll(rememberScrollState())) {
                                block.rows.take(5).forEachIndexed { index, cells ->
                                    ReadingTableRow(cells, header = index == 0, cellWidth = 160.dp)
                                    if (index == 0) HorizontalDivider()
                                }
                            }
                        }
                    }
                }
            }
                if (state.truncated)
                    Text("Snapshot truncated", Modifier.align(Alignment.BottomStart).padding(12.dp),
                        style = MaterialTheme.typography.labelSmall)
                if (!hideControls) {
                    Column(
                        Modifier.align(Alignment.BottomEnd).padding(end = 12.dp, bottom = 4.dp),
                        horizontalAlignment = Alignment.End,
                    ) {
                        if ("remote-scroll" in state.capabilities) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.Bottom,
                            ) {
                                if (state.scrolling != null) {
                                    Surface(shape = MaterialTheme.shapes.extraLarge, tonalElevation = 4.dp) {
                                        CircularProgressIndicator(
                                            Modifier.padding(10.dp).size(18.dp).testTag("mirror-scroll-progress"),
                                            strokeWidth = 2.dp,
                                        )
                                    }
                                } else if (state.scrollError != null) {
                                    Surface(shape = MaterialTheme.shapes.large, tonalElevation = 4.dp) {
                                        Text(
                                            state.scrollError,
                                            Modifier.widthIn(max = 224.dp).padding(10.dp),
                                            style = MaterialTheme.typography.bodySmall,
                                            maxLines = 3,
                                        )
                                    }
                                }
                                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    FilledTonalIconButton(
                                        onClick = { session.scrollRemote(ScrollDirection.UP) },
                                        enabled = state.canScrollRemote(ScrollDirection.UP),
                                    ) { Icon(Icons.Default.KeyboardArrowUp, "Scroll Up") }
                                    FilledTonalIconButton(
                                        onClick = { session.scrollRemote(ScrollDirection.DOWN) },
                                        enabled = state.canScrollRemote(ScrollDirection.DOWN),
                                    ) { Icon(Icons.Default.KeyboardArrowDown, "Scroll Down") }
                                }
                            }
                        }
                        if (!state.follow)
                            FilledTonalIconButton(
                                onClick = { session.setFollow(true) },
                                enabled = state.scrolling == null,
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
                        Text("Frozen detail", Modifier.weight(1f).align(Alignment.CenterVertically),
                            style = MaterialTheme.typography.titleMedium)
                        TextButton(onClick = { clipboard.setText(AnnotatedString(frozen.raw)) }) { Text("Copy") }
                        TextButton(onClick = { detail = null }) { Text("Done") }
                    }
                    if (frozen is Block.Table) {
                        Box(Modifier.weight(1f).fillMaxWidth().horizontalScroll(rememberScrollState())) {
                            LazyColumn(Modifier.testTag("mirror-frozen-table"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                itemsIndexed(frozen.rows) { index, cells ->
                                    ReadingTableRow(cells, header = index == 0, cellWidth = 220.dp)
                                }
                            }
                        }
                    } else {
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
}

internal suspend fun LazyListState.revealEnd(lastIndex: Int) {
    // A newly composed reader can start while the parent is still being measured.
    withFrameNanos { }
    scrollToItem(lastIndex)
    val layout = layoutInfo
    val last = layout.visibleItemsInfo.lastOrNull { it.index == lastIndex } ?: return
    val remaining = last.offset + last.size + layout.afterContentPadding - layout.viewportEndOffset
    if (remaining > 0) scrollBy(remaining.toFloat())
}

@Composable
private fun ReadingPreview(title: String, open: () -> Unit, content: @Composable () -> Unit) {
    Surface(
        Modifier.fillMaxWidth().padding(vertical = 6.dp), shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
                TextButton(onClick = open) { Text("Expand") }
            }
            content()
        }
    }
}

@Composable
private fun ReadingTableRow(cells: List<String>, header: Boolean, cellWidth: Dp) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        cells.forEach { cell ->
            SelectionContainer(Modifier.width(cellWidth)) {
                Text(cell, fontWeight = if (header) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

private fun historyCaptureTime(seconds: Double): String =
    java.text.DateFormat.getTimeInstance().format(java.util.Date((seconds * 1_000).toLong()))

@Composable
private fun HistoryReader(session: Session, state: SessionState) {
    val scroll = rememberLazyListState(session.historyScrollIndex, session.historyScrollOffset)
    var oldTime by remember { mutableStateOf(state.historyTime) }
    var oldStart by remember { mutableIntStateOf(state.historyOffset) }
    LaunchedEffect(state.historyTime, state.historyOffset) {
        if (state.historyTime != null && state.historyTime == oldTime && oldStart > state.historyOffset) {
            withFrameNanos { }
            scroll.scrollToItem(oldStart - state.historyOffset + 1)
        }
        oldTime = state.historyTime
        oldStart = state.historyOffset
    }
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.firstVisibleItemIndex to scroll.firstVisibleItemScrollOffset }.collect { (index, offset) ->
            session.historyScrollIndex = index
            session.historyScrollOffset = offset
        }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = session::showLive) { Text("Back to Live") }
            state.historyTime?.let { Text("Captured ${historyCaptureTime(it)}", style = MaterialTheme.typography.labelSmall) }
            Spacer(Modifier.weight(1f))
            TextButton(
                onClick = { session.loadHistory(refresh = true) },
                enabled = !state.loadingHistory && state.status == Status.live,
            ) { Text("Refresh History") }
        }
        if (state.historyTruncated)
            Text("Older lines omitted. The first retained line may begin mid-paragraph.", style = MaterialTheme.typography.labelSmall)
        if (state.history.isNotEmpty()) {
            val last = state.historyOffset + state.history.size
            Text("Loaded lines ${state.historyOffset + 1}–$last", style = MaterialTheme.typography.labelSmall)
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("mirror-output"), state = scroll) {
            item(key = "earlier") {
                TextButton(
                    onClick = { session.loadHistory() },
                    enabled = !state.loadingHistory && state.historyOffset > 0 && state.status == Status.live,
                ) { Text("Load Earlier 200 Lines") }
            }
            itemsIndexed(state.history, key = { index, _ -> state.historyOffset + index }) { _, line ->
                SelectionContainer { Text(line.ifEmpty { " " }, Modifier.fillMaxWidth()) }
            }
        }
        if (state.loadingHistory) LinearProgressIndicator(Modifier.fillMaxWidth().testTag("mirror-history-progress"))
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
                    }
                    if (draft.complete) TextButton(onClick = { session.bringHostDraft(draft) }, enabled = value.composition == null) {
                        Text("Bring Draft Here")
                    }
                    TextButton(onClick = session::dismissHostDraft) { Text("Cancel") }
                }
            }
        }
        val note = when {
            state.hostDraft != null -> null
            state.delivery in setOf(Delivery.UNKNOWN, Delivery.REJECTED) -> state.hint
            state.replacedHostDraft && state.draft.isEmpty() -> state.hint
            state.status != Status.live -> null
            state.keyRefusal != null -> state.keyRefusal
            "launch-profile" !in state.capabilities -> "This Host does not accept messages for this pane."
            else -> null
        }
        if (note != null) {
            val problem = state.delivery in setOf(Delivery.UNKNOWN, Delivery.REJECTED) || state.keyRefusal != null
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
                Text(note, Modifier.fillMaxWidth().padding(10.dp), style = MaterialTheme.typography.bodySmall,
                    color = if (problem) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.height(6.dp))
        }
        if (state.delivery == Delivery.UNKNOWN) {
            var preview by remember(session.id) { mutableStateOf(false) }
            TextButton(onClick = { preview = !preview }) { Text("Submitted message") }
            if (preview) SelectionContainer {
                Text(state.submittedText.orEmpty(), Modifier.heightIn(max = 120.dp).verticalScroll(rememberScrollState()))
            }
        }
        TextField(
            value,
            { next ->
                if (next.composition != null || !next.selection.collapsed) gesture.cancel()
                else gesture.validate(next.text, next.selection.start)
                value = next
                session.setDraft(next.text)
            },
            placeholder = {
                Text(when {
                    state.pane?.agent != null -> "Message"
                    "shell-send" in state.capabilities -> "Command"
                    else -> "Terminal is read-only here"
                })
            },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
            ),
            trailingIcon = {
                val sending = state.delivery == Delivery.PENDING
                FilledIconButton(
                    modifier = Modifier.size(34.dp),
                    enabled = if (showStop) state.canAct else state.canSend && value.composition == null,
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = if (showStop) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                        contentColor = Color.White,
                        disabledContainerColor = if (sending) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f),
                        disabledContentColor = Color.White,
                    ),
                    onClick = {
                        gesture.cancel()
                        if (showStop) stop = true else session.submit()
                    },
                ) {
                    when {
                        sending -> CircularProgressIndicator(Modifier.size(16.dp).testTag("composer-sending"), color = Color.White, strokeWidth = 2.dp)
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
                TextButton(onClick = session::queryReceipt, enabled = state.status == Status.live) { Text("Check receipt") }
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
internal fun LaunchDialog(session: Session, projectPanes: Set<String>? = null, dismiss: () -> Unit) {
    val model = session.launch
    val state by model.state.collectAsState()
    var worktrees by remember { mutableStateOf(false) }
    var profiles by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val worktree = state.worktrees.firstOrNull { it.string("id") == state.worktree }
    val profile = state.profiles.firstOrNull { it.string("id") == state.profile }
    LaunchedEffect(model, projectPanes) { model.open(projectPanes) }
    LaunchedEffect(state.created) { if (state.created != null) dismiss() }
    ModalBottomSheet(onDismissRequest = { if (!state.creating) dismiss() }) {
        Column(
            Modifier.align(Alignment.CenterHorizontally).widthIn(max = 720.dp).fillMaxWidth()
                .verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("New Session", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                IconButton(onClick = { model.open(projectPanes) }, enabled = !state.creating && !state.loading && !state.uncertain) {
                    Icon(Icons.Default.Refresh, "Refresh projects and Agent Profiles")
                }
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                state.prompt, model::setPrompt, placeholder = { Text("What would you like to work on?") },
                modifier = Modifier.fillMaxWidth(), maxLines = 6, enabled = !state.creating,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                Box {
                    AssistChip(
                        onClick = { worktrees = true }, leadingIcon = { Icon(Icons.Default.Folder, null) },
                        label = {
                            val label = worktree?.let {
                                val project = it.string("root_path").trimEnd('/').substringAfterLast('/').ifBlank { "/" }
                                "$project · ${it.string("name")}"
                            }
                            Text(label ?: "Choose a project", maxLines = 1, overflow = TextOverflow.Ellipsis)
                        },
                        enabled = state.worktrees.isNotEmpty() && !state.creating,
                    )
                    DropdownMenu(worktrees, { worktrees = false }) {
                        state.worktrees.groupBy { it.string("root_path") }.forEach { (root, trees) ->
                            ListItem(headlineContent = { Text(root.substringAfterLast('/')) },
                                supportingContent = { Text(root) })
                            trees.forEach { tree ->
                                DropdownMenuItem(
                                    text = {
                                        Column {
                                            Text(tree.string("name"))
                                            Text(tree.string("path"), style = MaterialTheme.typography.bodySmall)
                                        }
                                    },
                                    leadingIcon = {
                                        if (tree.string("id") == state.worktree) Icon(Icons.Default.Check, "Selected")
                                    },
                                    onClick = { model.selectWorktree(tree.string("id")); worktrees = false },
                                )
                            }
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
                                        if (!entry.canLaunchProfile()) Text(
                                            if (!entry.flag("enabled")) "Disabled"
                                            else entry.record("availability").optionalString("reason") ?: "Unavailable",
                                            style = MaterialTheme.typography.bodySmall,
                                        )
                                    }
                                },
                                leadingIcon = { entry.optionalString("runtime")?.let { AgentMark(it) } },
                                enabled = entry.canLaunchProfile(),
                                onClick = { model.selectProfile(entry.string("id")); profiles = false },
                            )
                        }
                    }
                }
            }
            val tooLong = state.prompt.toByteArray().size > Wire.MAX_INPUT
            Text(
                state.error ?: if (tooLong) "The message is too long."
                else "Uses the Host Profile’s model, permissions and launch settings.",
                color = if (state.error != null || tooLong) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
            if (!state.loading && state.worktrees.isEmpty()) Text(
                "Open a project in Prowl on the Mac, then refresh.", style = MaterialTheme.typography.bodySmall,
            )
            if (!state.loading && state.profiles.isEmpty()) Text(
                "Configure an Agent Profile in Prowl on the Mac, then refresh.", style = MaterialTheme.typography.bodySmall,
            )
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
