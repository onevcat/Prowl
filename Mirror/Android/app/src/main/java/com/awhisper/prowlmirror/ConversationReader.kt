package com.awhisper.prowlmirror

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.google.gson.JsonObject

private fun JsonObject.bounded(key: String): String? =
    getAsJsonObject(key)?.let {
        val text = it.optionalString("text") ?: return@let null
        if (it.optionalFlag("truncated") == true) "$text\n…" else text
    }

internal sealed interface ChatRow {
    val key: Long
    data class Event(val event: ConversationEvent) : ChatRow {
        override val key = event.sequence
    }
    data class Tools(val events: List<ConversationEvent>) : ChatRow {
        override val key = events.first().sequence
    }
}

private fun toolCompletions(events: List<ConversationEvent>): Map<Long, ConversationEvent> {
    val starts = mutableMapOf<String, Long>()
    val matched = mutableMapOf<Long, ConversationEvent>()
    for (event in events) {
        when (event.kind) {
            "session.changed", "session.pending", "session.ended" -> starts.clear()
            "tool.started" -> event.data.optionalString("id")?.let { starts[it] = event.sequence }
            "tool.completed" -> starts.remove(event.data.optionalString("id"))?.let { matched[it] = event }
        }
    }
    return matched
}

internal fun chatRows(events: List<ConversationEvent>): List<ChatRow> =
    chatRows(events, toolCompletions(events))

private fun chatRows(events: List<ConversationEvent>, completed: Map<Long, ConversationEvent>): List<ChatRow> {
    val absorbed = duplicatePromptAnswers(events)
    val attached = completed.values.mapTo(mutableSetOf()) { it.sequence }
    val result = mutableListOf<ChatRow>()
    val tools = mutableListOf<ConversationEvent>()
    fun flushTools() {
        if (tools.isNotEmpty()) {
            result += ChatRow.Tools(tools.toList())
            tools.clear()
        }
    }
    for (event in events) {
        if (event.sequence in absorbed) continue
        when (event.kind) {
            "tool.started" -> tools += event
            "tool.completed" -> if (event.sequence !in attached) tools += event
            "user.unqueued" -> {
                val text = event.data.bounded("text")
                val index = result.indexOfLast {
                    it is ChatRow.Event && it.event.kind == "user.queued" && it.event.data.bounded("text") == text
                }
                if (index >= 0) result.removeAt(index)
            }
            "assistant.message", "assistant.reasoning", "user.message", "user.queued", "session.changed",
            "context.compacted", "notice", "prompt.resolved", "subagent.started", "subagent.completed",
            "session.started", "session.pending", "session.ended" -> {
                if (event.kind == "notice" && event.data.optionalString("level") == "debug") continue
                if (event.kind == "assistant.reasoning" && event.data.bounded("summary").isNullOrEmpty()) continue
                flushTools()
                result += ChatRow.Event(event)
            }
        }
    }
    flushTools()
    return result
}

private fun duplicatePromptAnswers(events: List<ConversationEvent>): Set<Long> {
    val absorbed = mutableSetOf<Long>()
    val screen = mutableMapOf<String, Int>()
    val transcript = mutableListOf<Pair<Long, String>>()
    val opened = mutableMapOf<String, String>()
    fun finishTurn() {
        for ((sequence, title) in transcript) {
            val count = screen[title] ?: continue
            if (count == 1) screen.remove(title) else screen[title] = count - 1
            absorbed += sequence
        }
        screen.clear()
        transcript.clear()
    }
    for (event in events) {
        when (event.kind) {
            "user.message", "assistant.message", "session.changed", "session.pending", "session.ended" -> {
                finishTurn()
                if (event.kind.startsWith("session.")) opened.clear()
            }
            "prompt.opened", "prompt.resolved" -> {
                val id = event.data.optionalString("id") ?: continue
                val title = event.data.optionalString("title")
                    ?: event.data.getAsJsonArray("questions")?.firstOrNull()?.asJsonObject?.optionalString("question")
                if (event.kind == "prompt.opened") {
                    if (title != null) opened[id] = title
                } else {
                    val openTitle = opened.remove(id)
                    val question = title ?: openTitle ?: continue
                    if (id.startsWith("screen:")) screen[question] = (screen[question] ?: 0) + 1
                    else transcript += event.sequence to question
                }
            }
        }
    }
    finishTurn()
    return absorbed
}

internal const val CHAT_PAGE = 120

@Composable
internal fun ConversationReader(session: Session, feed: ConversationFeed, hideLatest: Boolean = false) {
    val tools = remember(feed.events) { toolCompletions(feed.events) }
    val allRows = remember(feed.events, tools) { chatRows(feed.events, tools) }
    var visibleLimit by remember(session.id) { mutableIntStateOf(session.reading.chatVisibleLimit) }
    val rows = remember(allRows, visibleLimit) { allRows.takeLast(visibleLimit) }
    val hidden = allRows.size - rows.size
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = session.reading.chatScrollIndex,
        initialFirstVisibleItemScrollOffset = session.reading.chatScrollOffset,
    )
    val working = feed.agentState == "working"
    val lastIndex = rows.lastIndex + (if (feed.gap) 1 else 0) + (if (hidden > 0) 1 else 0) +
        (if (working) 1 else 0) + (if (rows.isEmpty()) 1 else 0)
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var userScrolled by remember { mutableStateOf(false) }
    var follow by remember { mutableStateOf(session.reading.chatFollowsLatest) }
    val awayFromLatest by remember {
        derivedStateOf { listState.layoutInfo.visibleItemsInfo.isNotEmpty() && listState.canScrollForward }
    }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect {
            if (it is androidx.compose.foundation.interaction.DragInteraction.Start) {
                userScrolled = true
                focus.clearFocus()
                keyboard?.hide()
                follow = false
            }
        }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex to listState.firstVisibleItemScrollOffset }
            .collect { (index, offset) ->
                session.reading.chatScrollIndex = index
                session.reading.chatScrollOffset = offset
            }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to listState.canScrollForward }.collect { (moving, canAdvance) ->
            if (userScrolled && !moving && !canAdvance && listState.layoutInfo.visibleItemsInfo.isNotEmpty()) {
                follow = true
                userScrolled = false
            }
        }
    }
    val viewport by remember(listState, lastIndex) {
        derivedStateOf {
            val info = listState.layoutInfo
            info.viewportSize.height to info.visibleItemsInfo.lastOrNull { it.index == lastIndex }?.size
        }
    }
    LaunchedEffect(feed.sequence, follow, lastIndex, viewport) {
        session.reading.chatFollowsLatest = follow
        if (follow && lastIndex >= 0) listState.revealEnd(lastIndex)
    }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 56.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (feed.gap) item(key = "gap") { ChatCaption("Earlier messages are not available on this device.") }
            if (hidden > 0) item(key = "earlier") {
                OutlinedButton(
                    onClick = {
                        follow = false
                        visibleLimit += CHAT_PAGE
                        session.reading.chatVisibleLimit = visibleLimit
                    },
                    modifier = Modifier.testTag("conversation-earlier"),
                ) { Text("Show ${minOf(hidden, CHAT_PAGE)} earlier") }
            }
            if (rows.isEmpty()) item {
                if (session.state.collectAsState().value.status == Status.live) Column {
                    Text("Nothing here yet", style = MaterialTheme.typography.titleSmall)
                    ChatCaption("Messages appear as you and the agent write them.")
                } else ChatCaption("Waiting for conversation…")
            }
            items(rows, key = { it.key }) { row ->
                Box(Modifier.widthIn(max = 720.dp).fillMaxWidth().testTag("chat-reading-column")) {
                    when (row) {
                        is ChatRow.Event -> MessageRow(row.event)
                        is ChatRow.Tools -> ToolSteps(row.events, tools)
                    }
                }
            }
            if (working) item(key = "working") {
                Row(Modifier.widthIn(max = 720.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    AgentStateLabel("working")
                }
            }
        }
        if (!hideLatest && !follow && awayFromLatest && lastIndex >= 0) {
            Box(Modifier.align(Alignment.BottomCenter).widthIn(max = 720.dp).fillMaxWidth().padding(horizontal = 12.dp)) {
                FilledTonalIconButton(onClick = { follow = true }, modifier = Modifier.align(Alignment.CenterEnd)) {
                    Icon(Icons.Default.ArrowDownward, "Latest")
                }
            }
        }
    }
}

@Composable
private fun MessageRow(event: ConversationEvent) {
    val data = event.data
    when (event.kind) {
        "user.queued" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            val text = splitInjectedText(data.getAsJsonObject("text")?.optionalString("text").orEmpty()).first
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 8.dp).semantics {
                        contentDescription = "Queued: $text"
                    },
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Schedule, null, Modifier.size(16.dp))
                    Text(text, maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    Text("queued", Modifier.testTag("queued-status"), style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        "user.message" -> BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            var expanded by remember { mutableStateOf(false) }
            var instructions by remember { mutableStateOf(false) }
            val message = data.getAsJsonObject("text")
            val text = message?.optionalString("text").orEmpty()
            val (body, injected) = splitInjectedText(text)
            val truncated = message?.optionalFlag("truncated") == true
            val stamp = event.timestamp?.let {
                runCatching {
                    val local = java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault())
                    java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT).format(local)
                }.getOrNull()
            }
            val origin = data.optionalString("origin")
                ?.takeUnless { it == "manual" || it == "human" }
            val isLong = body.codePointCount(0, body.length) > 700 || body.lineSequence().count { it.isNotEmpty() } > 12
            Column(
                modifier = Modifier.widthIn(max = (maxWidth - 48.dp).coerceAtLeast(maxWidth * .72f)),
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Surface(
                    color = if (isSystemInDarkTheme()) Color(0xFF22625C) else Color(0xFF2E7D77),
                    contentColor = Color.White,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                ) {
                    Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                        val images = data.optionalInteger("images") ?: 0
                        if (images > 0) Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Image, null, Modifier.size(14.dp))
                            Text("$images ${if (images == 1) "image" else "images"}", style = MaterialTheme.typography.labelSmall)
                        }
                        SelectionContainer {
                            Text(
                                body,
                                maxLines = if (!isLong || expanded) Int.MAX_VALUE else 12,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                        }
                        if (isLong) TextButton(onClick = { expanded = !expanded }) {
                            Text(if (expanded) "Show less" else "Show more", color = Color.White)
                        }
                        if (injected != null) {
                            TextButton(onClick = { instructions = !instructions }) { Text("Prowl instructions", color = Color.White) }
                            if (instructions) SelectionContainer {
                                Text(injected + if (truncated) "…" else "",
                                    style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        if (truncated && injected == null) Text("…")
                    }
                }
                val metadata = listOfNotNull(origin, stamp).joinToString(" · ")
                if (metadata.isNotBlank()) ChatCaption(metadata)
            }
        }
        "assistant.message" -> Column {
            data.getAsJsonObject("text")?.let {
                ChatMarkdown(it.optionalString("text").orEmpty())
                if (it.optionalFlag("truncated") == true) ChatCaption("Message truncated by the Host.")
            }
        }
        "assistant.reasoning" -> data.bounded("summary")?.let { ChatCaption(it) }
        "session.started", "session.changed", "session.pending", "session.ended" -> {
            val label = when (event.kind) {
                "session.started" -> "Session started"
                "session.pending" -> "Waiting for session"
                "session.ended" -> "Session ended"
                else -> "Session changed"
            }
            ChatCaption(listOfNotNull(label, data.optionalString("model")).joinToString(" · "))
        }
        "context.compacted" -> ChatCaption("Context compacted")
        "prompt.resolved" -> {
            val outcome = data.optionalString("outcome")?.replaceFirstChar { it.uppercase() } ?: "Answered"
            ChatCaption(listOfNotNull(outcome, data.optionalString("title")).joinToString(" · "))
        }
        "subagent.started", "subagent.completed" -> {
            val status = if (event.kind == "subagent.started") "Subagent started" else "Subagent finished"
            ChatCaption(listOfNotNull(status, data.optionalString("type"), data.bounded("summary")).joinToString(" · "))
        }
        "notice" -> ChatCaption(data.optionalString("text").orEmpty())
    }
}

@Composable
private fun ChatCaption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ToolSteps(calls: List<ConversationEvent>, ends: Map<Long, ConversationEvent>) {
    var expanded by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<ConversationEvent?>(null) }
    fun end(event: ConversationEvent) =
        if (event.kind == "tool.completed") event.data else ends[event.sequence]?.data
    val failed = calls.count {
        val result = end(it)
        result != null && (result.optionalString("status") != "succeeded" || (result.optionalInteger("exitCode") ?: 0) != 0)
    }
    val running = calls.lastOrNull { end(it) == null && it.data.optionalString("kind") != "question" }
        ?.let(::toolTitle)
    Column {
        TextButton(onClick = { expanded = !expanded }) {
            Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
            Spacer(Modifier.width(4.dp))
            Text("${calls.size} ${if (calls.size == 1) "tool call" else "tool calls"}")
            if (failed > 0) Text(" · $failed failed", color = MaterialTheme.colorScheme.error)
            if (running != null) Text(" · $running", maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
        if (expanded) calls.forEach { call ->
            TextButton(onClick = { detail = call }) {
                ChatCaption(listOfNotNull(toolTitle(call), end(call)?.optionalString("status") ?: "Running").joinToString(" · "))
            }
        }
    }
    detail?.let { call ->
        val result = end(call)
        AlertDialog(
            onDismissRequest = { detail = null },
            title = { Text(toolTitle(call)) },
            text = {
                Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    listOf(
                        "Command" to call.data.optionalString("command"),
                        "Path" to call.data.optionalString("path"),
                        "Changes" to result?.bounded("diff"),
                        "Output" to result?.bounded("output"),
                    ).forEach { (label, value) ->
                        if (value != null) {
                            Text(label, style = MaterialTheme.typography.titleSmall)
                            SelectionContainer { Text(value, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)) }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { detail = null }) { Text("Done") } },
        )
    }
}

private fun toolTitle(call: ConversationEvent): String =
    call.data.optionalString("title") ?: call.data.optionalString("name") ?: "Tool call"

@Composable
internal fun MirrorActions(session: Session, state: SessionState, promptHeight: Dp = Dp.Unspecified, showKeys: Boolean = true) {
    val prompt = state.openPrompt
    val agentState = if (state.chat) state.conversation.agentState ?: state.pane?.rosterState else state.pane?.rosterState
    val choices = prompt?.getAsJsonArray("choices")
    if (state.status == Status.live && prompt != null && choices != null && choices.size() > 0 &&
        "prompt-respond" in state.capabilities
    ) {
        val id = prompt.string("id")
        val answer = state.promptAction?.takeIf { it.id == id }
        val sent = state.answeredPrompt == id
        val canAnswer = state.canAct && !sent
        OutlinedCard(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("prompt-panel"),
            border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = .35f)),
        ) {
            Column(
                Modifier.heightIn(max = promptHeight).verticalScroll(rememberScrollState()).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    when (prompt.optionalString("kind")) {
                        "permission" -> "Blocked · Permission"
                        "question" -> "Blocked · Question"
                        "planApproval" -> "Blocked · Plan approval"
                        "auth" -> "Blocked · Sign-in"
                        "trust" -> "Blocked · Trust"
                        "elicitation" -> "Blocked · Input"
                        else -> "Needs your answer"
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error,
                )
                prompt.optionalString("title")?.let { Text(it, style = MaterialTheme.typography.titleSmall) }
                prompt.bounded("detail")?.let {
                    Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceVariant) {
                        SelectionContainer {
                            Text(
                                it, Modifier.fillMaxWidth().heightIn(max = 132.dp).verticalScroll(rememberScrollState()).padding(8.dp),
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            )
                        }
                    }
                }
                fun progressFor(choice: String) = state.actionPending && answer?.choice == choice
                choices.forEach {
                    val choice = it.asJsonObject
                    val choiceID = choice.string("id")
                    val checked = choice.optionalFlag("checked")
                    Surface(
                        onClick = { session.answerPrompt(prompt, choiceID) }, enabled = canAnswer,
                        modifier = Modifier.fillMaxWidth().testTag("prompt-choice-$choiceID"),
                        shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant,
                    ) {
                        Row(
                            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            when (checked) {
                                true -> Icon(Icons.Default.CheckBox, "Checked")
                                false -> Icon(Icons.Default.CheckBoxOutlineBlank, "Not checked")
                                null -> Text(choiceID, style = MaterialTheme.typography.labelMedium)
                            }
                            Column(Modifier.weight(1f)) {
                                Text(choice.string("label"))
                                choice.optionalString("description")?.let { ChatCaption(it) }
                            }
                            if (progressFor(choiceID)) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            else if (sent && answer?.choice == choiceID) Icon(Icons.Default.Check, "Sent")
                        }
                    }
                }
                if (prompt.optionalFlag("multiSelect") == true) {
                    Button(onClick = { session.answerPrompt(prompt, "submit") }, enabled = canAnswer) {
                        if (progressFor("submit")) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        else Text("Submit")
                    }
                }
                when {
                    answer?.error != null -> Text(answer.error, color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall)
                    sent -> ChatCaption("Sent to the Mac")
                    prompt.optionalFlag("freeform") == true -> ChatCaption("To type your own answer, use the Mac.")
                }
            }
        }
    } else if (agentState == "blocked" && state.status == Status.live) {
        val reason = when (state.conversation.attentionKind) {
            "permission" -> "a permission decision"
            "question" -> "your answer"
            "auth" -> "sign-in"
            else -> "you"
        }
        Surface(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp), shape = MaterialTheme.shapes.medium,
            color = MaterialTheme.colorScheme.errorContainer,
        ) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Blocked · Waiting for $reason" + if (state.keysAvailable) "" else " on the Mac",
                    Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, maxLines = 2,
                )
                if (state.chat && state.keysAvailable)
                    TextButton(onClick = { session.showChat(false) }, enabled = state.canAct) { Text("Answer in Terminal") }
            }
        }
    }
    if (!state.chat && state.keysAvailable && showKeys) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
            Button(onClick = { session.sendKey("enter") }, enabled = state.canAct) { Text("Return") }
            val keys = if (state.pane?.agent != null)
                listOf("↑" to "up", "↓" to "down", "Esc" to "esc", "Tab" to "tab", "Shift+Tab" to "shift-tab",
                    "←" to "left", "→" to "right", "Ctrl+C" to "ctrl-c")
            else listOf("Ctrl+C" to "ctrl-c", "Tab" to "tab", "↑" to "up", "↓" to "down", "Esc" to "esc",
                "←" to "left", "→" to "right", "Shift+Tab" to "shift-tab")
            keys.forEach { (label, key) ->
                TextButton(onClick = { session.sendKey(key) }, enabled = state.canAct) { Text(label) }
            }
        }
    }
}

@Composable
internal fun StartingChat(kickoff: String) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(Modifier.widthIn(max = 720.dp).fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Surface(Modifier.fillMaxWidth(.85f), shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.secondaryContainer) {
                Text(kickoff, Modifier.padding(12.dp), maxLines = 12)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            ChatCaption("Starting session…")
        }
    }
}


internal fun splitInjectedText(text: String): Pair<String, String?> {
    val separator = "\n\n---\n"
    val marker = separator + "Prowl dispatch completion protocol v"
    val start = text.indexOf(marker).takeIf { it >= 0 } ?: text.lastIndexOf(separator)
        .takeIf { it >= 0 && text.length - it >= separator.length + "Prowl".length &&
            marker.startsWith(text.substring(it)) }
        ?: return text to null
    return text.substring(0, start).trim() to text.substring(start + separator.length)
}
