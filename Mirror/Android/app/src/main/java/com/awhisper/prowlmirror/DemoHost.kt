package com.awhisper.prowlmirror

import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * Demo connections use the same messages as a Host, with state scoped to one visit. The panes and
 * their scripts come from [DemoContent], ported from the iOS demo (docs-ai 098).
 */
internal class DemoHost(private val scope: CoroutineScope, panes: List<DemoPane> = DemoContent.standard()) {
    val address = Host("demo", name = DemoContent.HOST_NAME)
    private val run = uuid()
    private val panes = panes.associateByTo(linkedMapOf()) { it.id }
    private val connections = mutableSetOf<Connection>()
    /** The scripted work of each pane that is running now. */
    private val scripts = mutableMapOf<String, Job>()
    /** Messages sent while the agent worked; they start a turn when the current one ends. */
    private val queued = mutableMapOf<String, ArrayDeque<String>>()

    init {
        // Plays the work that runs without input, such as the working agent finishing.
        for (pane in panes) if (pane.autoplay.isNotEmpty()) play(pane, pane.autoplay)
    }

    fun close() {
        scripts.values.forEach(Job::cancel)
        scripts.clear()
        connections.toList().forEach(Connection::close)
    }

    private fun update(pane: DemoPane, events: List<JsonObject>) {
        pane.append(events)
        notifyPaneChanged(pane)
    }

    private fun notifyPaneChanged(pane: DemoPane) {
        connections.toList().forEach { it.paneChanged(pane) }
    }

    /** Runs [steps] on [pane]; steps without a delay apply at once, so a command's effect is visible in its reply. */
    private fun play(pane: DemoPane, steps: List<DemoStep>) {
        scripts.remove(pane.id)?.cancel()
        val immediate = steps.takeWhile { it.delay == 0L }
        immediate.forEach { update(pane, it.events) }
        val rest = steps.drop(immediate.size)
        if (rest.isEmpty()) {
            playQueued(pane)
            return
        }
        scripts[pane.id] = scope.launch {
            for (step in rest) {
                delay(step.delay)
                update(pane, step.events)
            }
            scripts.remove(pane.id)
            playQueued(pane)
        }
    }

    private fun playQueued(pane: DemoPane) {
        val message = queued[pane.id]?.removeFirstOrNull() ?: return
        update(pane, listOf(demoEvent("user.unqueued", obj("text" to obj("text" to message), "origin" to "human"))))
        play(pane, DemoContent.reply(message, pane.agentName))
    }

    /** Stop: the running tool and the turn end as interrupted, as an agent reports Escape. */
    private fun interrupt(pane: DemoPane) {
        scripts.remove(pane.id)?.cancel()
        update(pane, pane.interruptionEvents())
        playQueued(pane)
    }

    private fun resolve(pane: DemoPane, prompt: JsonObject, choice: JsonObject) {
        val declined = choice.string("label").lowercase().startsWith("no")
        val outcome = when {
            prompt.optionalString("kind") != "permission" -> "answered"
            declined -> "denied"
            else -> "allowed"
        }
        val resolved = prompt.deepCopy().apply {
            addProperty("outcome", outcome)
            addProperty("decidedBy", "mirror")
        }
        update(pane, listOf(demoEvent("prompt.resolved", resolved, source = "screen")))
        play(pane, pane.answers[choice.string("id")] ?: pane.answers["*"].orEmpty())
    }

    private data class History(val id: String, val capturedAt: Double, val lines: List<String>)

    val transport = TransportFactory { _, _, scope, receive, ready, _, _ ->
        Connection(scope, receive, ready).also { connections += it }
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
        private var scrolledBy = 0
        private var delivered = 0
        private var shownPrompt: String? = null
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
            connections -= this
            incoming.close()
            job.cancel()
        }

        private fun emit(kind: String, vararg fields: Pair<String, Any?>) = receive(control(kind, obj(*fields)))

        private fun snapshot(pane: DemoPane, since: Int) {
            delivered = pane.events.size
            emit("conversationSnapshot", "subscriptionID" to lease, "sequence" to delivered,
                "gap" to false, "events" to pane.events.drop(since))
        }

        private fun screen(force: Boolean = false) {
            val pane = selected ?: return
            val maximum = pane.maximumScroll
            scrolledBy = scrolledBy.coerceIn(0, maximum)
            emit("scrollState", "subscriptionID" to lease, "sequence" to ++frame,
                "atTop" to (scrolledBy >= maximum), "atBottom" to (scrolledBy == 0))
            receive(Packet.Text(lease, frame, 80, DemoPane.SCREEN_LINES, false, pane.screen(scrolledBy)))
            val prompt = pane.prompt
            if (pane.agent != null && (force || shownPrompt != prompt?.optionalString("id"))) {
                shownPrompt = prompt?.optionalString("id")
                emit("screenPrompt", "subscriptionID" to lease, "prompt" to prompt)
            }
        }

        private fun handle(message: Packet.Control) {
            when (message.kind) {
                "list" -> roster()
                "subscribe" -> {
                    val p = message.payload()
                    val pane = panes[canonical(p.string("paneID"))] ?: return
                    selected = pane
                    history = null
                    lease = uuid()
                    frame = 0
                    scrolledBy = 0
                    chat = p.string("representation") == "conversation-v1"
                    emit("subscribed", "paneID" to pane.id, "subscriptionID" to lease, "hostRunID" to run)
                    if (chat) snapshot(pane, p.optionalInteger("since")?.coerceIn(0, pane.events.size) ?: 0)
                    else screen(force = true)
                }
                "refresh" -> if (!chat) screen(force = true)
                "scroll" -> {
                    val p = message.payload()
                    if (selected == null) return
                    scrolledBy += if (p.string("direction") == "up") SCROLL_PAGE else -SCROLL_PAGE
                    screen()
                    emit("scrollResult", "subscriptionID" to lease, "requestID" to p.string("requestID"), "sequence" to frame)
                }
                "history" -> {
                    val pane = selected ?: return
                    val request = message.payload()
                    val historyID = request.optionalString("historyID")
                    val snapshot = if (historyID != null) history?.takeIf { it.id == historyID } ?: return
                    else History(uuid(), System.currentTimeMillis() / 1000.0, pane.historyLines).also { history = it }
                    val end = (request.optionalInteger("offset") ?: snapshot.lines.size).coerceIn(0, snapshot.lines.size)
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

        private fun roster() = emit(
            "panes", "hostRunID" to run, "hostName" to DemoContent.HOST_NAME,
            "capabilities" to listOf("text-v1", "conversation-v1", "launch-profile", "agent-input",
                "shell-send", "refresh", "remote-scroll", "agent-keys", "shell-keys", "history", "prompt-respond", "scroll-state-v1"),
            "panes" to panes.values.map { it.descriptor },
        )

        fun paneChanged(pane: DemoPane) {
            if (selected == null) roster()
            else if (selected == pane) {
                if (chat) publishEvents(pane) else screen()
            }
        }

        private fun publishEvents(pane: DemoPane) {
            val events = pane.events.drop(delivered)
            if (events.isEmpty()) return
            delivered = pane.events.size
            emit("conversationEvents", "subscriptionID" to lease, "sequence" to delivered, "events" to events)
        }

        private fun command(request: JsonObject): JsonObject {
            val kind = request.keySet().single()
            val args = request.record(kind).record("_0")
            fun success(name: String = kind, data: JsonObject = obj()) = obj("ok" to true, "command" to name, "data" to data)
            fun failure(name: String, code: String, message: String) =
                obj("ok" to false, "command" to name, "error" to obj("code" to code, "message" to message))
            fun delivered(name: String, text: String) =
                success(name, obj("input" to obj("bytes" to text.toByteArray().size, "trailing_enter_sent" to true)))
            return when (kind) {
                "list" -> success(data = obj(
                    "worktrees" to panes.values.map { it.worktree }.distinct().map { it.json },
                    "items" to panes.values.map {
                        obj("worktree" to it.worktree.json, "pane" to it.descriptor,
                            "task" to obj("status" to if (it.agentState == "working") "working" else "idle"))
                    },
                ))
                "profiles" -> success(data = obj("profiles" to DemoContent.profiles.map { it.json }))
                "create" -> {
                    val treeID = args.record("selector").getAsJsonObject("worktree")?.optionalString("_0")
                    val template = panes.values.firstOrNull { it.worktree.id == treeID }
                        ?: return failure("create", "NOT_FOUND", "The demo Mac has no such worktree.")
                    val launch = args.getAsJsonObject("launch")
                    val profile = launch?.optionalString("profile")?.let { id -> DemoContent.profiles.firstOrNull { it.id == id } }
                    val created = DemoPane.launched(template, profile)
                    created.append(created.agentStartEvents())
                    panes[created.id] = created
                    notifyPaneChanged(created)
                    val prompt = launch?.optionalString("prompt")?.trim().orEmpty()
                    if (profile != null && prompt.isNotEmpty()) play(created, DemoContent.reply(prompt, created.agentName))
                    success(data = obj("target" to obj("pane" to created.descriptor, "worktree" to created.worktree.json)))
                }
                "agentsInput" -> {
                    val text = args.string("prompt")
                    val pane = args.optionalString("pane")?.let { panes[canonical(it)] }?.takeIf { it.agent != null }
                        ?: return failure("agents.input", "NOT_FOUND", "The demo Mac has no such agent pane.")
                    when (pane.agentState) {
                        "blocked" -> return failure("agents.input", "INPUT_NOT_READY",
                            "${pane.agentName} is waiting on a question. Answer it first.")
                        "working" -> {
                            queued.getOrPut(pane.id) { ArrayDeque() }.addLast(text)
                            update(pane, listOf(demoEvent("user.queued", obj("text" to obj("text" to text), "origin" to "human"))))
                        }
                        else -> play(pane, DemoContent.reply(text, pane.agentName))
                    }
                    delivered("agents.input", text)
                }
                "send" -> {
                    val text = args.string("text")
                    val pane = args.getAsJsonObject("selector")?.getAsJsonObject("pane")?.optionalString("_0")
                        ?.let { panes[canonical(it)] } ?: return failure("send", "NOT_FOUND", "The demo Mac has no such pane.")
                    pane.runShellCommand(text)
                    notifyPaneChanged(pane)
                    delivered("send", text)
                }
                "promptRespond" -> {
                    val pane = args.optionalString("pane")?.let { panes[canonical(it)] }
                    val prompt = pane?.prompt?.takeIf { it.optionalString("id") == args.optionalString("prompt") }
                    val choice = prompt?.getAsJsonArray("choices")?.map { it.asJsonObject }
                        ?.firstOrNull { it.optionalString("id") == args.optionalString("choice") }
                    if (pane == null || choice == null)
                        return failure("prompt.respond", "PROMPT_CHANGED", "The question on the screen changed.")
                    resolve(pane, prompt, choice)
                    success("prompt.respond", obj("choice" to choice.string("id")))
                }
                "agentKeys" -> {
                    val pane = args.optionalString("pane")?.let { panes[canonical(it)] }
                        ?: return failure("agent.keys", "KEYS_REFUSED", "These keys cannot be sent.")
                    val keys = args.array("keys").map { it.asString }
                    if ("esc" in keys || "ctrl-c" in keys) {
                        val prompt = pane.prompt
                        // The last choice of a menu is the one that declines, as Esc does on the Mac.
                        val decline = prompt?.getAsJsonArray("choices")?.lastOrNull()?.asJsonObject
                        if (prompt != null && decline != null) resolve(pane, prompt, decline)
                        else if (pane.agentState == "working") interrupt(pane)
                    }
                    success("agent.keys", obj("keys" to keys))
                }
                "agentsDispatch" -> failure("agents.dispatch", "UNSUPPORTED", "The demo starts agents with New Session.")
                else -> failure(kind, "UNAVAILABLE", "Not available in Demo")
            }
        }
    }

    private companion object {
        /** Lines one remote scroll moves the demo screen. */
        const val SCROLL_PAGE = 24
    }
}
