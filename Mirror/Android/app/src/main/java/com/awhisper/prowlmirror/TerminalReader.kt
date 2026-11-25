package com.awhisper.prowlmirror

import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
internal fun Reading(session: Session, state: SessionState, hideControls: Boolean) {
    if (state.showsHistory) {
        HistoryReader(session, state)
        return
    }
    val blocks = remember(state.text) { Document.blocks(state.text) }
    var detail by remember(session.id) { mutableStateOf<Block?>(null) }
    key(session.id) {
        val scroll = rememberLazyListState(session.reading.liveScrollIndex, session.reading.liveScrollOffset)
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
                    session.reading.liveScrollIndex = index
                    session.reading.liveScrollOffset = offset
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
internal fun HistoryReader(session: Session, state: SessionState) {
    val scroll = rememberLazyListState(session.reading.historyScrollIndex, session.reading.historyScrollOffset)
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
            session.reading.historyScrollIndex = index
            session.reading.historyScrollOffset = offset
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
