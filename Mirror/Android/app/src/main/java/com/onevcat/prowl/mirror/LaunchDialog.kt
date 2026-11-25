package com.onevcat.prowl.mirror

import androidx.compose.foundation.*
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.*
import androidx.compose.ui.unit.dp

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
