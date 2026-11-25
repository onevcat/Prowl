package com.onevcat.prowl.mirror

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

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
