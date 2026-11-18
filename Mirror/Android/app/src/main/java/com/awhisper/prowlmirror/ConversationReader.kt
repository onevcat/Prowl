package com.awhisper.prowlmirror

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.google.gson.JsonObject
import kotlinx.coroutines.launch

private fun JsonObject.bounded(key: String): String? =
    getAsJsonObject(key)?.let {
        val text = it.optionalString("text") ?: return@let null
        if (it.optionalFlag("truncated") == true) "$text\n…" else text
    }

@Composable
internal fun ConversationReader(feed: ConversationFeed) {
    val tools = remember(feed.events) {
        feed.events.filter { it.kind == "tool.completed" }.associateBy { it.data.optionalString("id") }
    }
    val rows = remember(feed.events, tools) {
        val started = feed.events.filter { it.kind == "tool.started" }.map { it.data.optionalString("id") }.toSet()
        feed.events.filter {
            when (it.kind) {
                "tool.completed" -> it.data.optionalString("id") !in started
                "assistant.message", "assistant.reasoning", "user.message", "tool.started",
                "session.changed", "context.compacted", "notice" -> true
                else -> false
            }
        }
    }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val lastIndex = rows.size + if (feed.gap) 0 else -1
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect {
            if (it is androidx.compose.foundation.interaction.DragInteraction.Start) follow = false
        }
    }
    LaunchedEffect(rows.lastOrNull()?.sequence, follow) {
        if (follow && lastIndex >= 0) listState.scrollToItem(lastIndex)
    }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 56.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (feed.gap) item { Text("Some earlier messages are unavailable.", style = MaterialTheme.typography.bodySmall) }
            if (rows.isEmpty()) item { Text("Waiting for conversation…", style = MaterialTheme.typography.bodySmall) }
            items(rows, key = { it.sequence }) { event ->
                Box(Modifier.widthIn(max = 720.dp).fillMaxWidth()) {
                    ChatRow(event, tools[event.data.optionalString("id")])
                }
            }
        }
        if (!follow && lastIndex >= 0) {
            FilledTonalButton(
                onClick = { follow = true; scope.launch { listState.scrollToItem(lastIndex) } },
                modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
            ) { Text("Latest") }
        }
    }
}

@Composable
private fun ChatRow(event: ConversationEvent, toolEnd: ConversationEvent?) {
    val data = event.data
    when (event.kind) {
        "user.message" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = MaterialTheme.shapes.large) {
                SelectionContainer { Text(data.bounded("text").orEmpty(), Modifier.padding(12.dp)) }
            }
        }
        "assistant.message" -> SelectionContainer { Text(inlineMarkdown(data.bounded("text").orEmpty())) }
        "assistant.reasoning" -> data.bounded("summary")?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        "tool.started", "tool.completed" -> {
            var expanded by remember { mutableStateOf(false) }
            val end = toolEnd?.data ?: data.takeIf { event.kind == "tool.completed" }
            val label = data.optionalString("title") ?: data.optionalString("name") ?: "Tool call"
            Column {
                TextButton(onClick = { expanded = !expanded }) {
                    Text("$label · ${end?.optionalString("status") ?: "Running"}")
                }
                if (expanded) SelectionContainer {
                    Text(
                        listOfNotNull(data.optionalString("command"), data.optionalString("path"),
                            end?.bounded("diff"), end?.bounded("output")).joinToString("\n\n"),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    )
                }
            }
        }
        "session.changed" -> Text("Session changed", style = MaterialTheme.typography.labelMedium)
        "context.compacted" -> Text("Context compacted", style = MaterialTheme.typography.labelMedium)
        "notice" -> Text(data.optionalString("text").orEmpty(), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
internal fun MirrorActions(session: Session, state: SessionState) {
    val prompt = state.openPrompt
    val canAnswer = state.canAct && "prompt-respond" in state.capabilities
    var stop by remember { mutableStateOf(false) }
    val agentState = if (state.chat) state.conversation.agentState ?: state.pane?.agentState else state.pane?.agentState
    if (prompt != null && canAnswer && prompt.optionalString("id") != state.answeredPrompt) {
        ElevatedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
            Column(Modifier.padding(12.dp)) {
                Text(prompt.optionalString("title") ?: "Needs your answer", style = MaterialTheme.typography.titleSmall)
                prompt.bounded("detail")?.let { Text(it, maxLines = 5, style = MaterialTheme.typography.bodySmall) }
                prompt.getAsJsonArray("choices")?.forEach {
                    val choice = it.asJsonObject
                    val checked = choice.optionalFlag("checked")
                    val prefix = when (checked) {
                        true -> "☑ "
                        false -> "☐ "
                        null -> ""
                    }
                    TextButton(onClick = { session.answerPrompt(prompt, choice.string("id")) }) {
                        Text(prefix + choice.string("label"))
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
    if (agentState == "working" && state.pane?.agent != null && state.keysAvailable && state.draft.isBlank()) {
        TextButton(onClick = { stop = true }, enabled = state.canAct) { Text("Stop") }
    }
    if (stop) AlertDialog(
        onDismissRequest = { stop = false },
        title = { Text("Stop this agent?") },
        confirmButton = { TextButton(onClick = { stop = false; session.sendKey("esc") }) { Text("Stop") } },
        dismissButton = { TextButton(onClick = { stop = false }) { Text("Cancel") } },
    )
}
