package com.awhisper.prowlmirror

import com.google.gson.JsonObject
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

@Suppress("EnumEntryName")
enum class Status(val label: String) {
    disconnected("Connection lost"),
    connecting("Connecting…"),
    choosing("Choose a pane"),
    subscribing("Opening mirror…"),
    live("Live"),
    takenOver("Taken over by another device"),
    hostStopped("Host stopped sharing"),
    paneClosed("Host pane closed"),
}

enum class Delivery {
    NONE,
    PENDING,
    UNKNOWN,
    ACCEPTED,
    REJECTED,
}

data class HostDraft(val text: String, val complete: Boolean, val replaceable: Boolean, val discardable: Boolean)

data class PromptAction(val id: String, val choice: String, val error: String? = null)

data class SessionState(
    val host: Host,
    val hostName: String? = null,
    val status: Status = Status.disconnected,
    val panes: List<Pane> = emptyList(),
    val pane: Pane? = null,
    val text: String = "",
    val sequence: Long = 0,
    val truncated: Boolean = false,
    val error: String? = null,
    val capabilities: Set<String> = emptySet(),
    val draft: String = "",
    val draftRevision: Long = 0,
    val delivery: Delivery = Delivery.NONE,
    val hint: String = "Host checks readiness when you send.",
    val history: List<String> = emptyList(),
    val historyOffset: Int = 0,
    val historyTime: Double? = null,
    val historyTruncated: Boolean = false,
    val loadingHistory: Boolean = false,
    val showsHistory: Boolean = false,
    val follow: Boolean = true,
    val scrolling: ScrollDirection? = null,
    val scrollError: String? = null,
    val scrollCompletion: ScrollCompletion? = null,
    val scrollBounds: ScrollBounds = ScrollBounds(),
    val chat: Boolean = false,
    val kickoff: String? = null,
    val conversation: ConversationFeed = ConversationFeed(),
    val screenPrompt: JsonObject? = null,
    val actionPending: Boolean = false,
    val answeredPrompt: String? = null,
    val promptAction: PromptAction? = null,
    val hostDraft: HostDraft? = null,
    val broughtDraftPolicy: String? = null,
) {
    val canScrollRemote: Boolean
        get() = status == Status.live && !chat && "remote-scroll" in capabilities &&
            !showsHistory && scrolling == null

    fun canScrollRemote(direction: ScrollDirection): Boolean =
        canScrollRemote && scrollBounds.allows(direction)

    val needsPairing: Boolean
        get() = host.credential == null || error == "Device authentication failed" ||
            error == "Host identity changed. Pair again."

    val openPrompt: JsonObject?
        get() = if (chat) conversation.openPrompt else screenPrompt

    val keysAvailable: Boolean
        get() = status == Status.live && "agent-keys" in capabilities &&
            (pane?.agent != null || "shell-keys" in capabilities)

    val canAct: Boolean
        get() = status == Status.live && !actionPending && delivery != Delivery.PENDING &&
            delivery != Delivery.UNKNOWN

    val canSend: Boolean
        get() =
            canAct &&
                "launch-profile" in capabilities &&
                draft.isNotBlank() &&
                draft.toByteArray().size <= Wire.MAX_INPUT &&
                delivery != Delivery.PENDING &&
                delivery != Delivery.UNKNOWN
}

class HistoryGate {
    var id: String? = null
        private set

    var offset = 0
        private set

    private var total = 0
    private var time: Double? = null
    private var bytes = 0

    fun reset() {
        id = null
        offset = 0
        total = 0
        time = null
        bytes = 0
    }

    fun accept(p: JsonObject): List<String> {
        val newID = canonical(p.string("historyID"))
        val start = p.integer("offset")
        val count = p.integer("total")
        val stamp = p.get("capturedAt")?.asDouble ?: throw IOException("Missing history time")
        val lines =
            p.array("lines").map {
                require(it.isJsonPrimitive && it.asJsonPrimitive.isString)
                it.asString
            }
        require(
            stamp.isFinite() &&
                start >= 0 &&
                count >= 0 &&
                lines.size <= 200 &&
                start.toLong() + lines.size <= count
        )
        if (id != null)
            require(
                newID == id &&
                    count == total &&
                    stamp == time &&
                    start + lines.size == offset &&
                    start < offset
            )
        else require(start + lines.size == count)
        val size = lines.sumOf { it.toByteArray().size.toLong() + 1 }
        require(bytes + size <= 2 * 1024 * 1024 + 200) { "History exceeds capacity" }
        id = newID
        offset = start
        total = count
        time = stamp
        bytes += size.toInt()
        return lines
    }
}

class Session(
    host: Host,
    private val scope: CoroutineScope,
    private val factory: TransportFactory,
    onLaunch: ((Pane, String?) -> Unit)? = null,
    loadProfile: () -> String? = { null },
    saveProfile: (String) -> Unit = {},
) {
    val id = uuid()
    val state = MutableStateFlow(SessionState(host))
    val launch = LaunchModel(scope, ::command, loadProfile, saveProfile) { pane, kickoff ->
        if (onLaunch == null) choose(pane, kickoff = kickoff) else onLaunch(pane, kickoff)
    }
    private var transport: Transport? = null
    private var generation = 0
    private var requestedCompression = false
    private var lease: String? = null
    private var runID: String? = null
    private var intent = "ifFree"
    private var choseMode = false
    private var retryJob: Job? = null
    private var retryCount = 0
    private var suspended = false
    private val historyGate = HistoryGate()
    private var historyTimeout: Job? = null
    private var commandPending: Pair<String, CompletableDeferred<JsonObject>>? = null
    private var scrollTimeout: Job? = null
    private data class ScrollRequest(
        val id: String,
        val lease: String,
        val direction: ScrollDirection,
        val sequence: Long,
    )
    private var scrollRequest: ScrollRequest? = null
    private data class PendingScrollState(val sequence: Long, val bounds: ScrollBounds)
    private var pendingScrollState: PendingScrollState? = null
    private var expectsScrollState = false

    private data class Submission(
        val id: String,
        val runID: String,
        val pane: String,
        val text: String,
        val revision: Long,
    )

    private var submission: Submission? = null
    var chatVisibleLimit = CHAT_PAGE
    var chatScrollIndex = 0
    var chatScrollOffset = 0
    var chatFollowsLatest = true
    var liveScrollIndex = 0
    var liveScrollOffset = 0
    var historyScrollIndex = 0
    var historyScrollOffset = 0

    fun connect(code: String = "") {
        if (transport != null) return
        retryJob?.cancel()
        val attempt = ++generation
        requestedCompression = false
        state.update {
            it.copy(
                host = if (code.isNotBlank()) it.host.copy(credential = null) else it.host,
                status = Status.connecting,
                error = null,
            )
        }
        transport =
            factory.connect(
                state.value.host,
                code,
                scope,
                { packet ->
                    if (attempt == generation)
                        try {
                            receive(packet)
                        } catch (e: Exception) {
                            failed(e.message ?: "Invalid Host response")
                        }
                },
                { verified ->
                    if (attempt == generation) {
                        state.update { it.copy(host = verified) }
                        send(control("list"))
                    }
                },
                { reason -> if (attempt == generation) failed(reason) },
                { saved ->
                    if (attempt == generation) state.update { it.copy(host = saved) }
                },
            )
    }

    private fun failed(reason: String) {
        detach()
        state.update {
            it.copy(
                status =
                    if (it.status in setOf(Status.takenOver, Status.hostStopped, Status.paneClosed))
                        it.status
                    else Status.disconnected,
                error = reason,
                loadingHistory = false,
            )
        }
        if (
            !suspended &&
                state.value.status == Status.disconnected &&
                state.value.host.credential != null &&
                retryCount < 3
        ) {
            val wait = 1_000L shl retryCount++
            retryJob =
                scope.launch {
                    delay(wait)
                    retry()
                }
        }
    }

    private fun detach() {
        clearScroll()
        pendingScrollState = null
        expectsScrollState = false
        state.update { it.copy(scrollBounds = ScrollBounds()) }
        historyTimeout?.cancel()
        state.update { it.copy(loadingHistory = false) }
        generation++
        val old = transport
        transport = null
        old?.close()
        lease = null
        commandPending
            ?.second
            ?.completeExceptionally(IOException("Connection lost before confirmation"))
        commandPending = null
        if (state.value.delivery == Delivery.PENDING)
            state.update {
                it.copy(
                    delivery = Delivery.UNKNOWN,
                    hint = "Delivery unconfirmed. Check receipt or Host before sending again.",
                )
            }
    }

    fun close() {
        suspended = true
        retryJob?.cancel()
        detach()
    }

    fun background() {
        suspended = true
        retryJob?.cancel()
        if (transport != null) {
            detach()
            state.update { it.copy(status = Status.disconnected) }
        }
    }

    fun foreground() {
        suspended = false
        retryCount = 0
        if (state.value.status == Status.disconnected && !state.value.needsPairing) retry()
        else if (state.value.status == Status.live) {
            lease?.let { send(control("refresh", obj("subscriptionID" to it))) }
            queryReceipt()
        }
    }

    fun retry() {
        detach()
        intent = "ifFree"
        connect()
    }

    fun takeOver() {
        detach()
        retryCount = 0
        intent = "takeover"
        connect()
    }

    fun editHost(host: Host, code: String) {
        val prior = state.value
        val sameIdentity =
            host.credential?.hostID != null &&
                host.credential.hostID == prior.host.credential?.hostID
        if (!sameIdentity && prior.delivery in setOf(Delivery.PENDING, Delivery.UNKNOWN)) {
            state.update {
                it.copy(error = "Check the unconfirmed message before changing Host identity.")
            }
            return
        }
        detach()
        retryCount = 0
        historyGate.reset()
        state.value =
            state.value.copy(
                host = host,
                status = Status.disconnected,
                error = null,
                pane = if (sameIdentity) prior.pane else null,
                text = if (sameIdentity) prior.text else "",
                history = emptyList(),
                showsHistory = false,
            )
        intent = "ifFree"
        connect(code)
    }

    fun refreshPanes() {
        if (suspended) return
        send(control("list"))
    }

    fun updatePane(pane: Pane) {
        val previous = state.value.pane
        if (previous?.id != pane.id) return
        state.update { it.copy(pane = pane) }
        if (!choseMode && previous.conversation != "available" && pane.conversation == "available")
            switchMode(true)
        else if (state.value.chat && pane.conversation == "unsupported") switchMode(false)
    }

    fun choose(pane: Pane, takeover: Boolean = false, kickoff: String? = null) {
        choseMode = false
        submission = null
        historyGate.reset()
        state.update {
            it.copy(
                pane = pane,
                chat = pane.conversation == "available",
                kickoff = kickoff,
                conversation = ConversationFeed(),
                answeredPrompt = null,
                promptAction = null,
                hostDraft = null,
                broughtDraftPolicy = null,
                text = "",
                sequence = 0,
                history = emptyList(),
                historyTime = null,
                showsHistory = false,
                draft = "",
                delivery = Delivery.NONE,
                error = null,
            )
        }
        intent = if (takeover) "takeover" else "ifFree"
        subscribe()
    }

    fun showTerminalAfterKickoff() {
        choseMode = true
        state.update { it.copy(kickoff = null, chat = false) }
    }

    fun stopWaitingForKickoff() {
        state.update { it.copy(kickoff = null) }
    }

    fun showChat(chat: Boolean) {
        if (switchMode(chat)) choseMode = true
    }

    private fun switchMode(chat: Boolean): Boolean {
        val current = state.value
        if (current.chat == chat || current.status != Status.live || current.loadingHistory ||
            current.delivery == Delivery.PENDING || commandPending != null || current.scrolling != null
        ) return false
        if (chat && (current.pane?.conversation != "available" || "conversation-v1" !in current.capabilities)) return false
        state.update { it.copy(chat = chat, kickoff = null) }
        intent = "ifFree"
        subscribe()
        return true
    }

    private fun subscribe() {
        clearScroll()
        val pane = state.value.pane ?: return
        lease = null
        pendingScrollState = null
        val current = state.value
        expectsScrollState = !current.chat && "scroll-state-v1" in current.capabilities
        state.update { it.copy(status = Status.subscribing, sequence = 0, scrollBounds = ScrollBounds(), screenPrompt = null) }
        send(
            control(
                "subscribe",
                obj(
                    "paneID" to pane.id,
                    "representation" to if (current.chat) "conversation-v1" else "text-v1",
                    "intent" to intent,
                    "since" to current.conversation.sequence.takeIf { current.chat && it > 0 },
                    "includeScrollState" to true.takeIf { expectsScrollState },
                    "includeScreenPrompt" to true.takeIf { !current.chat && "prompt-respond" in current.capabilities },
                ),
            )
        )
    }

    fun sendKey(key: String) {
        val current = state.value
        val pane = current.pane ?: return
        if (!current.keysAvailable || key !in setOf("esc", "ctrl-c", "tab", "shift-tab", "up", "down", "left", "right", "enter")) return
        runAction(obj("agentKeys" to obj("_0" to obj("pane" to pane.id, "keys" to listOf(key)))))
    }

    fun answerPrompt(prompt: JsonObject, choice: String) {
        val current = state.value
        val pane = current.pane ?: return
        val id = prompt.string("id")
        if ("prompt-respond" !in current.capabilities || current.openPrompt != prompt ||
            current.answeredPrompt == id
        ) return
        val toggles = prompt.optionalFlag("multiSelect") == true && choice != "submit"
        runAction(obj("promptRespond" to obj("_0" to obj("pane" to pane.id, "prompt" to id, "choice" to choice))),
            prompt = PromptAction(id, choice), lockPrompt = !toggles)
    }

    private fun runAction(request: JsonObject, prompt: PromptAction? = null, lockPrompt: Boolean = false) {
        if (!state.value.canAct || commandPending != null) return
        state.update { it.copy(actionPending = true, error = null, promptAction = prompt) }
        scope.launch {
            try {
                val result = command(request)
                if (!result.flag("ok")) throw IOException(result.record("error").string("message"))
                if (prompt != null) state.update {
                    it.copy(answeredPrompt = if (lockPrompt) prompt.id else it.answeredPrompt)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val message = e.message ?: "Host action failed"
                state.update {
                    if (prompt != null) it.copy(promptAction = prompt.copy(error = message))
                    else it.copy(error = message)
                }
            } finally {
                state.update { it.copy(actionPending = false) }
            }
        }
    }

    fun setDraft(text: String) {
        state.update {
            if (it.draft == text) it
            else it.copy(draft = text, draftRevision = it.draftRevision + 1)
        }
    }

    fun setFollow(follow: Boolean) {
        state.update { it.copy(follow = follow) }
    }

    fun showLive() {
        state.update { it.copy(showsHistory = false) }
    }

    fun dismissHostDraft() {
        state.update { it.copy(hostDraft = null) }
    }

    fun bringHostDraft(draft: HostDraft) {
        state.update {
            if (!it.canAct || it.hostDraft != draft || !draft.complete || !draft.replaceable) it
            else it.copy(
                draft = listOf(draft.text, it.draft).filter(String::isNotBlank).joinToString("\n\n"),
                draftRevision = it.draftRevision + 1,
                hostDraft = null,
                broughtDraftPolicy = if (draft.discardable) "discard" else "replace",
            )
        }
    }

    fun replaceHostDraft(draft: HostDraft) {
        if (state.value.hostDraft == draft && draft.replaceable) submit("replace")
    }

    fun submit() = submit(state.value.broughtDraftPolicy)

    private fun submit(onDraft: String?) {
        val current = state.value
        val activeLease = lease ?: return
        val run = runID ?: return
        val pane = current.pane ?: return
        if (!current.canSend) return
        val item = Submission(uuid(), run, pane.id, current.draft, current.draftRevision)
        submission = item
        state.update { it.copy(delivery = Delivery.PENDING, hint = "Host is checking readiness…", hostDraft = null, broughtDraftPolicy = null) }
        scope.launch {
            try {
                val listing = command(Commands.list())
                if (lease != activeLease || submission != item) return@launch
                val input = Commands.input(listing, item.pane, item.text, onDraft)
                check(!input.has("agentsInput") || "agent-input" in state.value.capabilities) {
                    "Update Host to support interactive Agent input"
                }
                check(!input.has("send") || "shell-send" in state.value.capabilities) {
                    "Host cannot verify an empty command line for remote shell Send. Use an Agent Profile or control the shell on Host"
                }
                send(Commands.request(item.id, input, activeLease))
                delay(30_000)
                if (submission == item && state.value.delivery == Delivery.PENDING)
                    state.update {
                        it.copy(
                            delivery = Delivery.UNKNOWN,
                            hint =
                                "Delivery unconfirmed. Check receipt or Host before sending again.",
                        )
                    }
            } catch (e: Exception) {
                if (submission == item && state.value.delivery == Delivery.PENDING)
                    state.update {
                        it.copy(
                            delivery = Delivery.REJECTED,
                            hint = (e.message ?: "Input refused") + ". No input was sent.",
                        )
                    }
            }
        }
    }

    suspend fun command(command: JsonObject): JsonObject {
        check(
            transport != null &&
                commandPending == null &&
                "launch-profile" in state.value.capabilities
        ) {
            "Host command unavailable or pending"
        }
        val id = uuid()
        val result = CompletableDeferred<JsonObject>()
        commandPending = id to result
        send(Commands.request(id, command, lease))
        return try {
            withTimeout(30_000) { result.await() }
        } finally {
            if (commandPending?.first == id) commandPending = null
        }
    }

    fun queryReceipt() {
        val s = submission ?: return
        val active = lease ?: return
        if (
            s.runID == runID &&
                s.pane == state.value.pane?.id &&
                state.value.delivery in setOf(Delivery.PENDING, Delivery.UNKNOWN)
        )
            send(
                control(
                    "commandReceipt",
                    obj("subscriptionID" to active, "commandReceiptID" to s.id),
                )
            )
    }

    fun acknowledgeUnknown() {
        if (state.value.delivery == Delivery.UNKNOWN) {
            submission = null
            state.update {
                it.copy(delivery = Delivery.NONE, hint = "Host checks readiness when you send.")
            }
        }
    }

    fun loadHistory(refresh: Boolean = false) {
        val active = lease ?: return
        if (state.value.chat || state.value.loadingHistory || "history" !in state.value.capabilities) return
        clearScroll()
        if (refresh) {
            historyGate.reset()
            state.update { it.copy(history = emptyList(), historyOffset = 0, historyTime = null, historyTruncated = false) }
        }
        if (historyGate.id != null && historyGate.offset == 0) {
            state.update { it.copy(showsHistory = true) }
            return
        }
        state.update { it.copy(showsHistory = true, loadingHistory = true) }
        send(
            control(
                "history",
                obj(
                    "subscriptionID" to active,
                    "historyID" to historyGate.id,
                    "offset" to historyGate.offset.takeIf { historyGate.id != null },
                ),
            )
        )
        historyTimeout?.cancel()
        historyTimeout =
            scope.launch {
                delay(8_000)
                if (lease == active && state.value.loadingHistory)
                    state.update {
                        it.copy(loadingHistory = false, error = "History timed out. Retry history.")
                    }
            }
    }

    fun scrollRemote(direction: ScrollDirection) {
        val active = lease ?: return
        if (!state.value.canScrollRemote(direction)) return
        val request = ScrollRequest(uuid(), active, direction, state.value.sequence)
        scrollRequest = request
        state.update {
            it.copy(scrolling = direction, scrollCompletion = null, follow = false, scrollError = null)
        }
        scrollTimeout = scope.launch {
            delay(5_000)
            if (scrollRequest?.id == request.id) {
                clearScroll()
                state.update {
                    it.copy(scrollError = "Remote scroll timed out. Check the current screen before trying again.")
                }
            }
        }
        send(control("scroll", obj(
            "requestID" to request.id,
            "direction" to direction.wireName,
            "subscriptionID" to active,
        )))
    }

    fun consumeScrollCompletion(id: String) {
        state.update {
            if (it.scrollCompletion?.requestID == id) it.copy(scrollCompletion = null) else it
        }
    }

    private fun clearScroll() {
        scrollTimeout?.cancel()
        scrollTimeout = null
        scrollRequest = null
        state.update { it.copy(scrolling = null, scrollCompletion = null, scrollError = null) }
    }

    private fun scrollResult(p: JsonObject) {
        val request = scrollRequest ?: return
        if (canonical(p.string("requestID")) != request.id ||
            canonical(p.string("subscriptionID")) != request.lease) return
        val sequence = p.longInteger("sequence")
        require(sequence > request.sequence && sequence <= state.value.sequence) {
            "Remote scroll result has no matching frame"
        }
        clearScroll()
        state.update { it.copy(scrollCompletion = ScrollCompletion(request.id, request.direction)) }
    }

    private fun receiveScrollState(p: JsonObject) {
        require(expectsScrollState && state.value.status == Status.live &&
            canonical(p.string("subscriptionID")) == lease) { "Unexpected scroll state" }
        val sequence = p.longInteger("sequence")
        require(pendingScrollState == null && sequence > state.value.sequence) {
            "Invalid scroll state sequence"
        }
        pendingScrollState = PendingScrollState(
            sequence, ScrollBounds(p.optionalFlag("atTop"), p.optionalFlag("atBottom")),
        )
    }

    private fun receive(packet: Packet) {
        if (packet is Packet.Text) {
            // Frames from the previous representation can precede the new lease.
            if (state.value.status == Status.subscribing) return
            require(packet.text.toByteArray().size <= 1024 * 1024) {
                "Text snapshot exceeds capacity"
            }
            require(
                state.value.status == Status.live &&
                    packet.lease == lease &&
                    packet.sequence > state.value.sequence
            ) {
                "Invalid frame lease or sequence"
            }
            val bounds = if (expectsScrollState) {
                val pending = pendingScrollState
                require(pending != null && pending.sequence == packet.sequence) {
                    "Text frame has no matching scroll state"
                }
                pending.bounds
            } else ScrollBounds()
            pendingScrollState = null
            state.update {
                it.copy(
                    scrollBounds = bounds,
                    text = packet.text,
                    sequence = packet.sequence,
                    truncated = packet.truncated,
                )
            }
            send(
                control(
                    "acknowledge",
                    obj("subscriptionID" to lease, "sequence" to packet.sequence),
                )
            )
            return
        }
        packet as Packet.Control
        val p = packet.payload()
        if (state.value.status == Status.subscribing &&
            packet.kind in setOf("conversationSnapshot", "conversationEvents", "scrollState", "screenPrompt")
        ) return
        when (packet.kind) {
            "panes" -> {
                val caps = p.array("capabilities").map { it.asString }.toSet()
                require("text-v1" in caps) { "Update Host to support text mirrors" }
                if (Wire.DEFLATE in caps && !requestedCompression) {
                    requestedCompression = true
                    send(control("compress"))
                }
                val hostRun = canonical(p.string("hostRunID"))
                val sameRun = runID == hostRun
                runID = hostRun
                val panes = p.array("panes").map { Pane.parse(it.asJsonObject) }
                state.update {
                    val updatedPane = panes.firstOrNull { pane -> pane.id == it.pane?.id }
                    it.copy(
                        panes = panes,
                        hostName = p.optionalString("hostName") ?: it.hostName,
                        pane = updatedPane ?: it.pane,
                        capabilities = caps,
                        chat = if (it.status == Status.live) it.chat else
                            it.chat && "conversation-v1" in caps && updatedPane?.conversation == "available",
                        conversation = if (sameRun) it.conversation else ConversationFeed(),
                        answeredPrompt = it.answeredPrompt.takeIf { sameRun },
                        promptAction = it.promptAction.takeIf { sameRun },
                    )
                }
                if (state.value.pane == null) state.update { it.copy(status = Status.choosing) }
                else if (panes.none { it.id == state.value.pane?.id })
                    state.update { it.copy(status = Status.paneClosed) }
                else if (state.value.status != Status.live) {
                    if (!choseMode && "conversation-v1" in caps && state.value.pane?.conversation == "available")
                        state.update { it.copy(chat = true, kickoff = null) }
                    subscribe()
                }
            }
            "subscribed" -> {
                clearScroll()
                pendingScrollState = null
                require(canonical(p.string("paneID")) == state.value.pane?.id)
                lease = canonical(p.string("subscriptionID"))
                runID = canonical(p.string("hostRunID"))
                retryCount = 0
                historyTimeout?.cancel()
                historyGate.reset()
                state.update {
                    it.copy(
                        status = Status.live,
                        error = null,
                        scrollBounds = ScrollBounds(),
                        history = emptyList(),
                        historyOffset = 0,
                        historyTime = null,
                        historyTruncated = false,
                        showsHistory = false,
                        loadingHistory = false,
                    )
                }
                queryReceipt()
            }
            "ended" -> {
                val status =
                    when (p.string("reason")) {
                        "takenOver" -> Status.takenOver
                        "hostStopped" -> Status.hostStopped
                        "paneClosed" -> Status.paneClosed
                        else -> throw IOException("Invalid end reason")
                    }
                state.update { it.copy(status = status, error = null) }
                retryJob?.cancel()
                detach()
            }
            "screenPrompt" -> {
                require(!state.value.chat && lease != null && canonical(p.string("subscriptionID")) == lease)
                val prompt = p.getAsJsonObject("prompt")
                state.update { it.copy(screenPrompt = prompt) }
            }
            "conversationSnapshot", "conversationEvents" -> {
                val active = lease ?: throw IOException("Conversation has no active lease")
                require(state.value.chat && canonical(p.string("subscriptionID")) == active)
                val snapshot = packet.kind == "conversationSnapshot"
                val sequence = p.longInteger("sequence")
                val events = p.array("events")
                if (snapshot && sequence < state.value.conversation.sequence) {
                    // A feed can expire and be recreated without a Host restart.
                    require(events.isEmpty) { "Conversation snapshot moved backwards" }
                    state.update { it.copy(conversation = ConversationFeed()) }
                    intent = "ifFree"
                    subscribe()
                    return
                }
                state.update { it.copy(conversation = it.conversation.accept(p, snapshot)) }
                if (!events.isEmpty) send(control("acknowledge", obj("subscriptionID" to active, "sequence" to sequence)))
            }
            "failure" -> {
                val error = p.string("error")
                if (error.startsWith("CONVERSATION_UNSUPPORTED") && state.value.chat) {
                    state.update { it.copy(chat = false) }
                    intent = "ifFree"
                    subscribe()
                } else if (error.startsWith("SCROLL_UNAVAILABLE") || error.startsWith("SCROLL_BUSY")) {
                    val request = scrollRequest
                    if (request != null &&
                        p.optionalString("subscriptionID")?.let(::canonical) == request.lease &&
                        p.optionalString("requestID")?.let(::canonical) == request.id) {
                        clearScroll()
                        state.update { it.copy(scrollError = error) }
                    }
                } else if (
                    error.startsWith("HISTORY_UNAVAILABLE") &&
                        state.value.loadingHistory &&
                        p.optionalString("subscriptionID")?.let(::canonical) == lease
                ) {
                    historyTimeout?.cancel()
                    state.update { it.copy(error = error, loadingHistory = false) }
                } else {
                    if (error.startsWith("PANE_BUSY"))
                        state.update { it.copy(status = Status.takenOver) }
                    failed(error)
                }
            }
            "scrollResult" -> scrollResult(p)
            "scrollState" -> receiveScrollState(p)
            "historyPage" -> {
                require(
                    canonical(p.string("subscriptionID")) == lease && state.value.loadingHistory
                )
                val lines = historyGate.accept(p)
                historyTimeout?.cancel()
                state.update {
                    it.copy(
                        history = lines + it.history,
                        historyOffset = historyGate.offset,
                        historyTime = p.get("capturedAt").asDouble,
                        historyTruncated = p.flag("truncated"),
                        loadingHistory = false,
                    )
                }
            }
            "commandResult" -> {
                val response = p.record("commandResponse")
                val id = canonical(response.string("requestID"))
                val result = response.record("response")
                if (commandPending?.first == id) commandPending?.second?.complete(result)
                else delivery(id, result)
            }
            else -> throw IOException("Unexpected Host message: ${packet.kind}")
        }
    }

    private fun delivery(id: String, response: JsonObject) {
        val s = submission ?: return
        if (s.id != id || state.value.delivery !in setOf(Delivery.PENDING, Delivery.UNKNOWN)) return
        val data = response.getAsJsonObject("data")
        val accepted =
            response.flag("ok") &&
                response.optionalString("command") in setOf("send", "agents.input") &&
                data?.getAsJsonObject("input")?.let {
                    it.integer("bytes") == s.text.toByteArray().size &&
                        it.flag("trailing_enter_sent")
                } == true
        val error = response.getAsJsonObject("error")
        val rejection =
            error?.optionalString("code")?.takeUnless {
                it in setOf("REMOTE_COMMAND_UNCONFIRMED", "DISPATCH_FAILED", "SEND_FAILED")
            }
        val details = error?.getAsJsonObject("details")?.getAsJsonObject("input")
        val hostDraft = details?.takeIf { rejection != null && it.optionalString("reason") == "draft" }
            ?.getAsJsonObject("draft")?.let { draft ->
                HostDraft(
                    draft.string("text"),
                    draft.optionalFlag("is_complete") == true,
                    details.optionalFlag("replaceable") == true,
                    details.optionalFlag("discardable") == true,
                )
            }
        val recovery = data?.getAsJsonObject("input")?.getAsJsonObject("replaced_draft")
        state.update {
            it.copy(
                hostDraft = hostDraft,
                delivery =
                    if (accepted) Delivery.ACCEPTED
                    else if (rejection != null) Delivery.REJECTED else Delivery.UNKNOWN,
                draft = if (accepted && it.draftRevision == s.revision) "" else it.draft,
                hint =
                    if (accepted) when {
                        recovery?.optionalString("recovery") == "stash" -> "Sent. The Mac agent stashed its draft."
                        recovery != null -> "Sent. The Mac draft was replaced."
                        else -> "Sent"
                    }
                    else
                        error?.optionalString("message")
                            ?: "Delivery unconfirmed. Check Host before sending again.",
            )
        }
    }

    private fun send(packet: Packet.Control) {
        transport?.send(packet)
    }
}
