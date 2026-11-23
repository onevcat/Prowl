package com.awhisper.prowlmirror

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant
import kotlinx.coroutines.delay

@Composable
internal fun MirrorOnboarding(pair: () -> Unit, demo: () -> Unit) {
    val uri = LocalUriHandler.current
    val intro: @Composable () -> Unit = {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Image(painterResource(R.drawable.prowl_mark), null, Modifier.size(112.dp).clip(RoundedCornerShape(26.dp)))
            Spacer(Modifier.height(28.dp))
            Text("Prowl Mirror", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text(
                "Follow the agents on your Mac, answer them, and start new ones — from here.",
                Modifier.padding(top = 8.dp), textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    val setup: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                listOf(
                    Icons.Default.LaptopMac to "On the Mac, open the Remote Mirror button in the Prowl toolbar.",
                    Icons.Default.QrCode to "Choose Add a Device to show a pairing code.",
                    Icons.Default.Smartphone to "Scan the code here, or type the address and code.",
                ).forEach { (icon, text) ->
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
                        Text(text)
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
            Button(onClick = pair, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Icon(Icons.Default.QrCodeScanner, null)
                Spacer(Modifier.width(8.dp))
                Text("Pair with a Mac")
            }
            TextButton(onClick = demo) { Text("Try the Demo") }
            TextButton(onClick = { uri.openUri("https://prowl.cat/") }) { Text("New to Prowl? Visit prowl.cat") }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (maxWidth > maxHeight) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = maxHeight).verticalScroll(rememberScrollState()).padding(24.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Box(Modifier.weight(1f).testTag("onboarding-brand"), contentAlignment = Alignment.Center) {
                    Box(Modifier.widthIn(max = 380.dp)) { intro() }
                }
                Box(Modifier.weight(1f).testTag("onboarding-setup"), contentAlignment = Alignment.Center) {
                    Box(Modifier.widthIn(max = 420.dp)) { setup() }
                }
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Column(Modifier.widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(36.dp)) {
                    Box(Modifier.fillMaxWidth().testTag("onboarding-brand"), contentAlignment = Alignment.Center) { intro() }
                    Box(Modifier.testTag("onboarding-setup")) { setup() }
                }
            }
        }
    }
}

internal val Pane.rosterState: String
    get() = displayState ?: agentState ?: "idle"

internal fun rosterProjects(panes: List<Pane>, filter: String?): List<Pair<String, List<Pane>>> =
    panes.filter { filter == null || (it.agent != null && it.rosterState == filter) }
        .groupBy { it.projectName ?: "Other" }
        .toList()
        .sortedWith(compareBy({ (_, entries) -> entries.mapNotNull(Pane::projectOrder).minOrNull() ?: Int.MAX_VALUE }, { it.first }))
        .map { (project, entries) ->
            project to entries.sortedWith(compareBy<Pane> { pane ->
                if (pane.agent == null) 4 else when (pane.rosterState) {
                    "blocked" -> 0
                    "working" -> 1
                    "done" -> 2
                    else -> 3
                }
            }.thenByDescending { changed(it) }.thenBy { it.tabTitle ?: it.title })
        }

private fun changed(pane: Pane): Instant? =
    pane.stateChangedAt?.let { runCatching { Instant.parse(it) }.getOrNull() }

private fun recent(pane: Pane): String? = changed(pane)?.let {
    val minutes = ((Instant.now().epochSecond - it.epochSecond) / 60).coerceAtLeast(0)
    when {
        minutes < 1 -> "Just now"
        minutes < 60 -> "${minutes}m ago"
        minutes < 1440 -> "${minutes / 60}h ago"
        else -> "${minutes / 1440}d ago"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentsHome(
    session: Session,
    state: SessionState,
    hosts: List<Host>,
    open: (Pane) -> Unit,
    selectHost: (Host) -> Unit,
    addHost: () -> Unit,
    manageHosts: () -> Unit,
    demo: Boolean = false,
    exitDemo: () -> Unit = {},
) {
    var filter by rememberSaveable(session.id) { mutableStateOf<String?>(null) }
    var switcher by remember { mutableStateOf(false) }
    var launch by rememberSaveable { mutableStateOf(false) }
    var launchProject by rememberSaveable { mutableStateOf<ArrayList<String>?>(null) }
    val title = hosts.firstOrNull { it.endpoint == state.host.endpoint }?.name
        ?: state.hostName ?: state.host.address
    val groups = remember(state.panes, filter) { rosterProjects(state.panes, filter) }
    val counts = state.panes.filter { it.agent != null }.groupingBy(Pane::rosterState).eachCount()
    LaunchedEffect(counts, filter) {
        if (filter != null && counts[filter] == null) filter = null
    }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = {},
            navigationIcon = {
                Box {
                    IconButton(onClick = { switcher = true }) { Icon(Icons.Default.Settings, "Settings") }
                    DropdownMenu(switcher, { switcher = false }) {
                        val top = hosts.take(5)
                        val active = hosts.firstOrNull { it.endpoint == state.host.endpoint }
                        val listed = if (active != null && active !in top) top.take(4) + active else top
                        listed.forEach { host ->
                            DropdownMenuItem(
                                text = {
                                    Column {
                                        Text(host.name ?: if (host.endpoint == state.host.endpoint) title else host.address)
                                        Text(host.endpoint, style = MaterialTheme.typography.labelSmall)
                                    }
                                },
                                leadingIcon = { if (host.endpoint == state.host.endpoint) Icon(Icons.Default.Check, "Selected") },
                                onClick = { switcher = false; if (host.endpoint != state.host.endpoint) selectHost(host) },
                            )
                        }
                        if (demo) {
                            DropdownMenuItem(text = { Text("Demo Mac · Sample data") }, onClick = {}, enabled = false)
                            DropdownMenuItem(text = { Text("Pair with a Mac") }, onClick = { switcher = false; exitDemo(); addHost() })
                            DropdownMenuItem(text = { Text("Exit Demo") }, onClick = { switcher = false; exitDemo() })
                        } else {
                            if (hosts.size > 5)
                                DropdownMenuItem(text = { Text("All Hosts…") }, onClick = { switcher = false; manageHosts() })
                            DropdownMenuItem(text = { Text("Add Host…") }, onClick = { switcher = false; addHost() })
                        }
                        DropdownMenuItem(text = { Text("Settings…") }, onClick = { switcher = false; manageHosts() })
                    }
                }
            },
            actions = {
                IconButton(
                    enabled = state.status == Status.choosing && "launch-profile" in state.capabilities,
                    onClick = { launchProject = null; launch = true },
                ) { Icon(Icons.Default.Add, "New Session") }
            },
        )
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.TopCenter) {
            LazyColumn(
                Modifier.widthIn(max = 720.dp).fillMaxWidth().fillMaxHeight(),
                contentPadding = PaddingValues(start = 18.dp, end = 18.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item {
                    Text(title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                    if (state.status != Status.choosing || state.error != null) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(state.error ?: state.status.label, Modifier.weight(1f),
                                color = if (state.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                            if (state.status == Status.disconnected) TextButton(onClick = {
                                if (state.needsPairing) addHost() else session.retry()
                            }) { Text(if (state.needsPairing) "Pair Again" else "Retry") }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf("blocked", "working", "done").forEach { status ->
                            val count = counts[status] ?: 0
                            val glyph = when (status) {
                                "blocked" -> Icons.Default.Error
                                "working" -> Icons.Default.HourglassTop
                                else -> Icons.Default.CheckCircle
                            }
                            val tint = when (status) {
                                "blocked" -> MaterialTheme.colorScheme.error
                                "working" -> Color(0xFFC25C12)
                                else -> Color(0xFF3979CD)
                            }
                            Card(
                                onClick = { filter = status.takeUnless { it == filter } },
                                modifier = Modifier.weight(1f),
                                colors = CardDefaults.cardColors(
                                    containerColor = if (filter == status) MaterialTheme.colorScheme.primary.copy(alpha = .12f)
                                    else MaterialTheme.colorScheme.surfaceVariant,
                                ),
                            ) {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(glyph, null, Modifier.size(18.dp), tint = tint.copy(alpha = if (count == 0) .45f else 1f))
                                        Spacer(Modifier.weight(1f))
                                        Text(count.toString(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                                    }
                                    Text(status.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
                items(groups, key = { it.first }) { (project, panes) ->
                    var terminals by rememberSaveable(session.id, project) { mutableStateOf(false) }
                    var projectMenu by remember { mutableStateOf(false) }
                    val shells = panes.filter { it.agent == null }
                    val metadata = panes.firstOrNull()
                    Column {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                metadata?.groupName?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    projectColor(metadata?.repositoryColor)?.let {
                                        Box(Modifier.size(8.dp).background(it, RoundedCornerShape(50)))
                                    }
                                    Text(project, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            Box {
                                IconButton(onClick = { projectMenu = true }) { Icon(Icons.Default.MoreHoriz, "$project actions") }
                                DropdownMenu(projectMenu, { projectMenu = false }) {
                                    DropdownMenuItem(
                                        text = { Text("New Session") },
                                        enabled = state.status == Status.choosing && "launch-profile" in state.capabilities,
                                        onClick = { projectMenu = false; launchProject = ArrayList(state.panes.filter { (it.projectName ?: "Other") == project }.map(Pane::id)); launch = true },
                                    )
                                }
                            }
                        }
                        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceVariant) {
                            Column {
                                val agents = panes.filter { it.agent != null }
                                agents.forEachIndexed { index, pane ->
                                    AgentRow(pane) { open(pane) }
                                    if (index < agents.lastIndex || shells.isNotEmpty()) HorizontalDivider(Modifier.padding(start = 52.dp, end = 12.dp))
                                }
                                if (shells.isNotEmpty()) {
                                    ListItem(
                                        headlineContent = { Text("${shells.size} ${if (shells.size == 1) "terminal" else "terminals"}") },
                                        leadingContent = { Icon(Icons.Default.Terminal, null) },
                                        trailingContent = { Icon(if (terminals) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null) },
                                        modifier = Modifier.clickable { terminals = !terminals },
                                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                                    )
                                    if (terminals) shells.forEach { pane -> AgentRow(pane) { open(pane) } }
                                }
                            }
                        }
                    }
                }
                if (groups.isEmpty() && state.status == Status.choosing)
                    item { Text(if (filter == null) "No running panes" else "No agents in this state") }
            }
        }
    }
    if (launch) LaunchDialog(session, projectPanes = launchProject?.toSet()) { launch = false }
}

@Composable
private fun AgentRow(pane: Pane, open: () -> Unit) {
    ListItem(
        headlineContent = { Text(pane.tabTitle ?: pane.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            val subtitle = listOfNotNull(pane.worktreeName ?: pane.subtitle, recent(pane)).joinToString(" · ")
            if (subtitle.isNotBlank()) Text(subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        leadingContent = {
            if (pane.agent == null) Icon(Icons.Default.Terminal, null)
            else AgentMark(pane.agent)
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (pane.agent != null) AgentStateLabel(pane.rosterState)
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.outline)
            }
        },
        modifier = Modifier.clickable(onClick = open),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

@Composable
internal fun AgentStateLabel(state: String) {
    val motion = androidx.compose.ui.platform.LocalContext.current.let {
        android.provider.Settings.Global.getFloat(it.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) != 0f
    }
    var frame by remember { mutableIntStateOf(0) }
    LaunchedEffect(state, motion) {
        while (state == "working" && motion) {
            delay(150)
            frame = (frame + 1) % 8
        }
    }
    val (label, color) = when (state) {
        "working" -> "${"☰☱☲☳☴☵☶☷"[frame]} Working" to Color(0xFFC25C12)
        "blocked" -> "● Blocked" to MaterialTheme.colorScheme.error
        "done" -> "● Done" to Color(0xFF3979CD)
        else -> return
    }
    Text(label, color = color, style = MaterialTheme.typography.labelSmall, maxLines = 1)
}

private fun projectColor(raw: String?): Color? = when (raw) {
    "red" -> Color(0xFFCE424F)
    "orange" -> Color(0xFFC96919)
    "yellow" -> Color(0xFFA17818)
    "green", "mint" -> Color(0xFF20856E)
    "teal", "cyan" -> Color(0xFF187F92)
    "blue", "indigo" -> Color(0xFF426BCE)
    "purple", "pink" -> Color(0xFF9852AF)
    else -> raw?.let { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrNull() }
}

@Composable
internal fun ManageHosts(model: MirrorModel, dismiss: () -> Unit, add: () -> Unit) {
    val uri = LocalUriHandler.current
    var rename by remember { mutableStateOf<Host?>(null) }
    var forget by remember { mutableStateOf<Host?>(null) }
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Settings") },
        text = {
            LazyColumn {
                if (!model.isDemo) item { Text("Paired Hosts", style = MaterialTheme.typography.titleSmall) }
                items(if (model.isDemo) emptyList() else model.saved, key = Host::endpoint) { host ->
                    ListItem(
                        headlineContent = { Text(host.name ?: host.address) },
                        supportingContent = { Text(host.endpoint) },
                        modifier = Modifier.clickable { model.add(host, ""); dismiss() },
                        trailingContent = {
                            Row {
                                IconButton(onClick = { name = host.name.orEmpty(); rename = host }) {
                                    Icon(Icons.Default.Edit, "Rename Host")
                                }
                                IconButton(onClick = { forget = host }) { Icon(Icons.Default.DeleteOutline, "Forget Host") }
                            }
                        },
                    )
                }
                item {
                    Spacer(Modifier.height(16.dp))
                    Text("About", style = MaterialTheme.typography.titleSmall)
                    ListItem(headlineContent = { Text("Version") }, trailingContent = { Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") })
                }
                listOf("Prowl Website" to "", "Privacy Policy" to "privacy", "Terms of Use" to "terms").forEach { (label, path) ->
                    item {
                        ListItem(
                            headlineContent = { Text(label) },
                            modifier = Modifier.clickable { uri.openUri("https://prowl.cat/$path") },
                            trailingContent = { Icon(Icons.AutoMirrored.Filled.OpenInNew, null) },
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = dismiss) { Text("Done") } },
        dismissButton = { if (!model.isDemo) TextButton(onClick = add) { Text("Add Host…") } },
    )
    rename?.let { host ->
        AlertDialog(
            onDismissRequest = { rename = null },
            title = { Text("Rename Host") },
            text = { OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true) },
            confirmButton = { TextButton(onClick = { model.renameHost(host, name); rename = null }) { Text("Save") } },
            dismissButton = { TextButton(onClick = { rename = null }) { Text("Cancel") } },
        )
    }
    forget?.let { host ->
        AlertDialog(
            onDismissRequest = { forget = null },
            title = { Text("Forget this Mac?") },
            text = { Text("You’ll need a new pairing code to connect again.") },
            confirmButton = { TextButton(onClick = { model.forgetHost(host); forget = null }) { Text("Forget") } },
            dismissButton = { TextButton(onClick = { forget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun AgentMark(name: String) {
    val asset = when (name) {
        "amp" -> R.drawable.agent_amp
        "antigravity" -> R.drawable.agent_antigravity
        "claude" -> R.drawable.agent_claudecode
        "cline" -> R.drawable.agent_cline
        "codex" -> R.drawable.agent_codex
        "copilot" -> R.drawable.agent_githubcopilot
        "cursor-agent" -> R.drawable.agent_cursor
        "devin" -> R.drawable.agent_devin
        "droid" -> R.drawable.agent_droid
        "gemini" -> R.drawable.agent_gemini
        "kimi" -> R.drawable.agent_kimi
        "opencode" -> R.drawable.agent_opencode
        "qwen" -> R.drawable.agent_qwen
        "grok" -> R.drawable.agent_grok
        "omp" -> R.drawable.agent_omp
        "pi" -> R.drawable.agent_pi
        "trae" -> R.drawable.agent_trae
        else -> null
    }
    val label = when (name) {
        "claude" -> "Claude Code"
        "copilot" -> "GitHub Copilot"
        "cursor-agent" -> "Cursor"
        "omp" -> "Oh My Pi"
        else -> name.replaceFirstChar { it.uppercase() }
    }
    if (asset == null) Icon(Icons.Default.AutoAwesome, label, Modifier.size(20.dp))
    else Icon(painterResource(asset), label, Modifier.size(20.dp))
}
