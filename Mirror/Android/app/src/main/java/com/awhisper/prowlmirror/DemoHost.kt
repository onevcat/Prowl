package com.awhisper.prowlmirror

import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/** Demo connections use the same messages as a Host, with state scoped to one visit. */
internal class DemoHost {
    val address = Host("demo", name = "Demo Mac")
    private val run = uuid()
    private val worktree = obj("id" to uuid(), "name" to "main", "path" to "/demo/Prowl", "root_path" to "/demo/Prowl")
    private val panes = linkedMapOf<String, DemoPane>()

    private class DemoPane(val descriptor: JsonObject) {
        val events = mutableListOf<JsonObject>()
        val shell = mutableListOf<String>()
        val id get() = descriptor.string("id")
        val agent get() = descriptor.optionalString("agent")
        fun add(kind: String, data: JsonObject, source: String = "transcript") {
            events += obj("seq" to events.size + 1, "kind" to kind, "source" to source, "data" to data)
        }
        fun message(kind: String, text: String) = add(kind, obj("text" to obj("text" to text)))
    }

    private val approval = obj(
        "id" to "screen:demo", "title" to "Apply the migration plan?",
        "choices" to listOf(obj("id" to "approve", "label" to "Approve"), obj("id" to "skip", "label" to "Skip")),
    )

    init {
        pane("Review the release", "codex").apply {
            message("user.message", "Check the release notes before we ship.")
            add("tool.started", obj("id" to "read", "kind" to "read", "title" to "Read release notes"))
            add("tool.completed", obj("id" to "read", "status" to "succeeded"))
            message("assistant.message", "The release notes are ready for review. You can reply from here.")
        }
        pane("Draft the migration guide", "claude").apply {
            message("user.message", "Summarize the migration steps.")
            message("assistant.message", "Update the Host first, then reconnect your devices.")
            descriptor.addProperty("displayState", "blocked")
            add("agent.status", obj("state" to "blocked"))
            add("prompt.opened", approval, source = "screen")
        }
        pane("Terminal", null).shell += (1..150).map { "Demo terminal · line $it" }
    }

    private fun pane(title: String, agent: String?): DemoPane {
        val id = uuid()
        return DemoPane(obj(
            "id" to id, "title" to title, "directory" to worktree.string("path"), "busy" to false,
            "projectName" to "Prowl", "tabTitle" to title, "worktreeName" to "main", "agent" to agent,
            "displayState" to if (agent != null) "done" else "terminal",
            "conversation" to if (agent != null) "available" else "unsupported",
        )).also { panes[id] = it }
    }

    private data class History(val id: String, val capturedAt: Double, val lines: List<String>)

    val transport = TransportFactory { _, _, scope, receive, ready, _, _ ->
        Connection(scope, receive, ready)
    }

    private inner class Connection(
        scope: CoroutineScope,
        private val receive: (Packet) -> Unit,
        ready: (Host) -> Unit,
    ) : Transport {
        private val incoming = Channel<Packet.Control>(Channel.UNLIMITED)
        private var selected: DemoPane? = null
        private var lease = uuid()
        private var chat = false
        private var frame = 0L
        private var firstRow = 1
        private var delivered = 0
        private var history: History? = null
        private val receipts = mutableMapOf<String, JsonObject>()
        private val job = scope.launch {
            yield()
            ready(address)
            for (message in incoming) handle(message)
        }

        override fun send(message: Packet.Control) {
            incoming.trySend(message)
        }

        override fun close() {
            incoming.close()
            job.cancel()
        }

        private fun emit(kind: String, vararg fields: Pair<String, Any?>) = receive(control(kind, obj(*fields)))

        private fun snapshot(pane: DemoPane, since: Int) {
            delivered = pane.events.size
            emit("conversationSnapshot", "subscriptionID" to lease, "sequence" to delivered,
                "gap" to false, "events" to pane.events.drop(since))
        }

        private fun screen() {
            val pane = selected ?: return
            val text = if (pane.agent == null)
                pane.shell.drop(firstRow - 1).take(24).joinToString("\n")
            else pane.events.mapNotNull { it.record("data").getAsJsonObject("text")?.optionalString("text") }
                .joinToString("\n\n")
            emit("scrollState", "subscriptionID" to lease, "sequence" to ++frame,
                "atTop" to (firstRow == 1), "atBottom" to (firstRow == lastPage(pane)))
            receive(Packet.Text(lease, frame, 80, 24, false, text))
            if (pane.agent != null) {
                val open = approval.takeIf { pane.descriptor.string("displayState") == "blocked" }
                emit("screenPrompt", "subscriptionID" to lease, "prompt" to open)
            }
        }

        private fun lastPage(pane: DemoPane) = if (pane.agent == null) (pane.shell.size - 23).coerceAtLeast(1) else 127

        private fun handle(message: Packet.Control) {
            when (message.kind) {
                "list" -> emit("panes", "hostRunID" to run, "hostName" to "Demo Mac",
                    "capabilities" to listOf("text-v1", "conversation-v1", "launch-profile", "agent-input",
                        "shell-send", "refresh", "remote-scroll", "agent-keys", "shell-keys", "history", "prompt-respond", "scroll-state-v1"),
                    "panes" to panes.values.map { it.descriptor })
                "subscribe" -> {
                    val p = message.payload()
                    val pane = panes[canonical(p.string("paneID"))] ?: return
                    selected = pane
                    history = null
                    lease = uuid()
                    frame = 0
                    firstRow = lastPage(pane)
                    chat = p.string("representation") == "conversation-v1"
                    emit("subscribed", "paneID" to pane.id, "subscriptionID" to lease, "hostRunID" to run)
                    if (chat) snapshot(pane, p.optionalInteger("since")?.coerceIn(0, pane.events.size) ?: 0)
                    else screen()
                }
                "refresh" -> if (!chat) screen()
                "scroll" -> {
                    val p = message.payload()
                    val pane = selected ?: return
                    firstRow = (firstRow + if (p.string("direction") == "up") -21 else 21).coerceIn(1, lastPage(pane))
                    screen()
                    emit("scrollResult", "subscriptionID" to lease, "requestID" to p.string("requestID"), "sequence" to frame)
                }
                "history" -> {
                    val pane = selected ?: return
                    val request = message.payload()
                    val historyID = request.optionalString("historyID")
                    val snapshot = if (historyID != null) history?.takeIf { it.id == historyID } ?: return
                    else History(
                        uuid(), System.currentTimeMillis() / 1000.0,
                        if (pane.agent == null) pane.shell.toList() else pane.events
                            .mapNotNull { it.record("data").getAsJsonObject("text")?.optionalString("text") }
                            .flatMap { it.lines() },
                    ).also { history = it }
                    val end = request.optionalInteger("offset") ?: snapshot.lines.size
                    val start = (end - 200).coerceAtLeast(0)
                    emit("historyPage", "subscriptionID" to lease, "historyID" to snapshot.id,
                        "offset" to start, "total" to snapshot.lines.size, "capturedAt" to snapshot.capturedAt,
                        "truncated" to false, "lines" to snapshot.lines.subList(start, end))
                }
                "command" -> {
                    val request = message.payload().record("commandRequest")
                    val id = request.string("requestID")
                    val result = command(request.record("request").record("command"))
                    receipts[id] = result
                    reply(id, result)
                }
                "commandReceipt" -> {
                    val id = message.payload().string("commandReceiptID")
                    receipts[id]?.let { reply(id, it) }
                }
            }
        }

        private fun reply(id: String, response: JsonObject) =
            emit("commandResult", "commandResponse" to obj("requestID" to id, "response" to response))

        private fun publishEvents(pane: DemoPane) {
            val events = pane.events.drop(delivered)
            delivered = pane.events.size
            emit("conversationEvents", "subscriptionID" to lease, "sequence" to delivered, "events" to events)
        }

        private fun command(request: JsonObject): JsonObject {
            val kind = request.keySet().single()
            val args = request.record(kind).record("_0")
            fun success(name: String = kind, data: JsonObject = obj()) = obj("ok" to true, "command" to name, "data" to data)
            return when (kind) {
                "list" -> success(data = obj("worktrees" to listOf(worktree),
                    "items" to panes.values.map { obj("worktree" to worktree, "pane" to it.descriptor) }))
                "profiles" -> success(data = obj("profiles" to listOf("codex", "claude").map {
                    obj("id" to it, "name" to it.replaceFirstChar(Char::uppercase), "runtime" to it,
                        "enabled" to true, "availability" to obj("status" to "available"))
                }))
                "create" -> {
                    val launch = args.record("launch")
                    val created = pane("New demo session", launch.string("profile"))
                    launch.optionalString("prompt")?.let {
                        created.message("user.message", it)
                        created.message("assistant.message", "This is a demo response. No message was sent to a Mac.")
                    }
                    success(data = obj("target" to obj("pane" to created.descriptor, "worktree" to worktree)))
                }
                "agentsInput", "send" -> {
                    val text = args.string(if (kind == "agentsInput") "prompt" else "text")
                    val pane = selected ?: return obj("ok" to false,
                        "error" to obj("code" to "NOT_FOUND", "message" to "No active demo pane"))
                    if (pane.descriptor.string("displayState") == "blocked")
                        return obj("ok" to false, "error" to obj(
                            "code" to "INPUT_NOT_READY", "message" to "The demo agent is waiting for your answer.",
                        ))
                    if (pane.agent != null) {
                        pane.message("user.message", text)
                        pane.message("assistant.message", "This is a demo response. No message was sent to a Mac.")
                    } else {
                        pane.shell += "$ $text"
                        pane.shell += "demo: Commands do not run in the demo."
                        firstRow = lastPage(pane)
                    }
                    if (chat) publishEvents(pane) else screen()
                    success(if (kind == "agentsInput") "agents.input" else "send",
                        obj("input" to obj("bytes" to text.toByteArray().size, "trailing_enter_sent" to true)))
                }
                "promptRespond" -> {
                    val pane = selected
                    if (pane == null || pane.descriptor.string("displayState") != "blocked")
                        return obj("ok" to false, "error" to obj("code" to "PROMPT_CLOSED", "message" to "The demo prompt is closed"))
                    pane.descriptor.addProperty("displayState", "done")
                    val outcome = if (args.string("choice") == "approve") "approved" else "dismissed"
                    pane.add("prompt.resolved", approval.deepCopy().apply { addProperty("outcome", outcome) }, source = "screen")
                    pane.add("agent.status", obj("state" to "done"))
                    if (chat) publishEvents(pane) else screen()
                    success()
                }
                "agentKeys" -> success()
                else -> obj("ok" to false, "error" to obj("code" to "UNAVAILABLE", "message" to "Not available in Demo"))
            }
        }
    }
}
