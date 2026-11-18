package com.awhisper.prowlmirror

import androidx.compose.foundation.gestures.scrollBy
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.google.gson.JsonObject

private fun JsonObject.bounded(key: String): String? =
    getAsJsonObject(key)?.let {
        val text = it.optionalString("text") ?: return@let null
        if (it.optionalFlag("truncated") == true) "$text\n…" else text
    }

private sealed interface ChatRow {
    val key: Long
    data class Event(val event: ConversationEvent) : ChatRow {
        override val key = event.sequence
    }
    data class Tools(val events: List<ConversationEvent>) : ChatRow {
        override val key = events.first().sequence
    }
}

private fun chatRows(events: List<ConversationEvent>): List<ChatRow> {
    val started = events.filter { it.kind == "tool.started" }.mapNotNull { it.data.optionalString("id") }.toSet()
    val lastQueue = events.lastOrNull { it.kind == "user.queued" || it.kind == "user.unqueued" }
        ?.takeIf { it.kind == "user.queued" }
    val result = mutableListOf<ChatRow>()
    val tools = mutableListOf<ConversationEvent>()
    fun flushTools() {
        if (tools.isNotEmpty()) {
            result += ChatRow.Tools(tools.toList())
            tools.clear()
        }
    }
    for (event in events) {
        when (event.kind) {
            "tool.started" -> tools += event
            "tool.completed" -> if (event.data.optionalString("id") !in started) tools += event
            "assistant.message", "assistant.reasoning", "user.message", "session.changed",
            "context.compacted", "notice", "prompt.resolved", "subagent.started", "subagent.completed" -> {
                flushTools()
                result += ChatRow.Event(event)
            }
        }
    }
    flushTools()
    if (lastQueue != null) result += ChatRow.Event(lastQueue)
    return result
}

@Composable
internal fun ConversationReader(session: Session, feed: ConversationFeed) {
    val tools = remember(feed.events) {
        feed.events.filter { it.kind == "tool.completed" }.associateBy { it.data.optionalString("id") }
    }
    val rows = remember(feed.events) { chatRows(feed.events) }
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = session.chatScrollIndex,
        initialFirstVisibleItemScrollOffset = session.chatScrollOffset,
    )
    val lastIndex = rows.size + if (feed.gap) 0 else -1
    var follow by remember { mutableStateOf(session.chatFollowsLatest) }
    val awayFromLatest by remember {
        derivedStateOf { listState.layoutInfo.visibleItemsInfo.isNotEmpty() && listState.canScrollForward }
    }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect {
            if (it is androidx.compose.foundation.interaction.DragInteraction.Start) follow = false
        }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex to listState.firstVisibleItemScrollOffset }
            .collect { (index, offset) ->
                session.chatScrollIndex = index
                session.chatScrollOffset = offset
            }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to listState.canScrollForward }.collect { (moving, canAdvance) ->
            if (!moving && !canAdvance && listState.layoutInfo.visibleItemsInfo.isNotEmpty()) follow = true
        }
    }
    LaunchedEffect(rows.lastOrNull()?.key, follow, lastIndex) {
        session.chatFollowsLatest = follow
        if (follow && lastIndex >= 0) {
            listState.scrollToItem(lastIndex)
            val layout = listState.layoutInfo
            val last = layout.visibleItemsInfo.lastOrNull { it.index == lastIndex }
            if (last != null) listState.scrollBy(
                (last.offset + last.size + layout.afterContentPadding - layout.viewportEndOffset).coerceAtLeast(0).toFloat(),
            )
        }
    }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 56.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (feed.gap) item { ChatCaption("Some earlier messages are unavailable.") }
            if (rows.isEmpty()) item { ChatCaption("Waiting for conversation…") }
            items(rows, key = { it.key }) { row ->
                Box(Modifier.widthIn(max = 720.dp).fillMaxWidth().testTag("chat-reading-column")) {
                    when (row) {
                        is ChatRow.Event -> MessageRow(row.event)
                        is ChatRow.Tools -> ToolSteps(row.events, tools)
                    }
                }
            }
        }
        if (!follow && awayFromLatest && lastIndex >= 0) {
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
        "user.message", "user.queued" -> BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            var expanded by remember { mutableStateOf(false) }
            var overflows by remember { mutableStateOf(false) }
            var instructions by remember { mutableStateOf(false) }
            val text = data.bounded("text").orEmpty()
            val marker = "\n\n---\nProwl dispatch completion protocol v"
            val injected = text.indexOf(marker).takeIf { it >= 0 }
            val stamp = event.timestamp?.let {
                runCatching {
                    val local = java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault())
                    java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT).format(local)
                }.getOrNull()
            }
            val origin = if (event.kind == "user.queued") "Queued" else data.optionalString("origin")
                ?.takeUnless { it == "manual" }?.replaceFirstChar { it.uppercase() }
            Surface(
                modifier = Modifier.widthIn(max = maxWidth * 0.86f),
                color = if (isSystemInDarkTheme()) Color(0xFF22625C) else Color(0xFF2E7D77),
                contentColor = Color.White,
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
            ) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                    val images = data.optionalInteger("images") ?: 0
                    if (images > 0) Text("$images ${if (images == 1) "image" else "images"}",
                        style = MaterialTheme.typography.labelSmall)
                    SelectionContainer {
                        Text(
                            if (injected == null) text else text.substring(0, injected).trimEnd(),
                            maxLines = if (expanded) Int.MAX_VALUE else 12,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            onTextLayout = { if (!expanded) overflows = it.hasVisualOverflow },
                        )
                    }
                    if (overflows || expanded) TextButton(onClick = { expanded = !expanded }) {
                        Text(if (expanded) "Show less" else "Show more", color = Color.White)
                    }
                    if (injected != null) {
                        TextButton(onClick = { instructions = !instructions }) { Text("Prowl instructions", color = Color.White) }
                        if (instructions) Text(text.substring(injected + "\n\n---\n".length), style = MaterialTheme.typography.bodySmall)
                    }
                    val metadata = listOfNotNull(origin, stamp).joinToString(" · ")
                    if (metadata.isNotBlank()) Text(metadata, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        "assistant.message" -> ChatMarkdown(data.bounded("text").orEmpty())
        "assistant.reasoning" -> data.bounded("summary")?.let { ChatCaption(it) }
        "session.changed" -> ChatCaption("Session changed")
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
private fun ToolSteps(calls: List<ConversationEvent>, ends: Map<String?, ConversationEvent>) {
    var expanded by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<ConversationEvent?>(null) }
    fun end(event: ConversationEvent) =
        if (event.kind == "tool.completed") event.data else ends[event.data.optionalString("id")]?.data
    val failed = calls.count { end(it)?.optionalString("status")?.let { status -> status != "succeeded" } == true }
    val running = calls.lastOrNull { end(it) == null }?.data?.optionalString("title")
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
internal fun MirrorActions(session: Session, state: SessionState) {
    val prompt = state.openPrompt
    val canAnswer = state.canAct && "prompt-respond" in state.capabilities
    val agentState = if (state.chat) state.conversation.agentState ?: state.pane?.agentState else state.pane?.agentState
    if (prompt != null && canAnswer && prompt.optionalString("id") != state.answeredPrompt) {
        ElevatedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
            Column(Modifier.padding(12.dp)) {
                Text(prompt.optionalString("title") ?: "Needs your answer", style = MaterialTheme.typography.titleSmall)
                prompt.bounded("detail")?.let {
                    Text(it, Modifier.heightIn(max = 100.dp).verticalScroll(rememberScrollState()),
                        style = MaterialTheme.typography.bodySmall)
                }
                prompt.getAsJsonArray("choices")?.forEach {
                    val choice = it.asJsonObject
                    val checked = choice.optionalFlag("checked")
                    val prefix = when (checked) {
                        true -> "☑ "
                        false -> "☐ "
                        null -> ""
                    }
                    TextButton(onClick = { session.answerPrompt(prompt, choice.string("id")) }) {
                        Column {
                            Text(prefix + choice.string("label"))
                            choice.optionalString("description")?.let { ChatCaption(it) }
                        }
                    }
                }
                if (prompt.optionalFlag("multiSelect") == true) {
                    Button(onClick = { session.answerPrompt(prompt, "submit") }) { Text("Submit") }
                }
            }
        }
    } else if (state.chat && agentState == "blocked" && state.keysAvailable) {
        TextButton(onClick = { session.showChat(false) }, enabled = state.canAct) { Text("Answer in Terminal") }
    }
    if (!state.chat && state.keysAvailable) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
            listOf("Esc" to "esc", "Ctrl+C" to "ctrl-c", "Shift+Tab" to "shift-tab", "Tab" to "tab",
                "↑" to "up", "↓" to "down", "←" to "left", "→" to "right", "Return" to "enter").forEach { (label, key) ->
                TextButton(onClick = { session.sendKey(key) }, enabled = state.canAct) { Text(label) }
            }
        }
    }
}
