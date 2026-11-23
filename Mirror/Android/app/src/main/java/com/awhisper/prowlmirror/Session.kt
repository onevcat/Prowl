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
    incompatible("Update Prowl on the Mac to use this version of Mirror"),
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
    val broughtDraftText: String? = null,
    val replacedHostDraft: Boolean = false,
    val submittedText: String? = null,
    val keyRefusal: String? = null,
    val localDemo: Boolean = false,
) {
    val canScrollRemote: Boolean
        get() = status == Status.live && !chat && "remote-scroll" in capabilities &&
            !showsHistory && scrolling == null

    fun canScrollRemote(direction: ScrollDirection): Boolean =
        canScrollRemote && scrollBounds.allows(direction)

    val needsPairing: Boolean
        get() = !localDemo && (host.credential == null || error == "Device authentication failed" ||
            error == "Host identity changed. Pair again." || error == UNRECOGNIZED_DEVICE)

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
    private val onRoster: ((Session, Host) -> Unit)? = null,
    localDemo: Boolean = false,
) {
    val id = uuid()
    val state = MutableStateFlow(SessionState(host, localDemo = localDemo))
    val launch = LaunchModel(scope, ::command, loadProfile, saveProfile) { pane, kickoff ->
        if (onLaunch == null) choose(pane, kickoff = kickoff, launched = true) else onLaunch(pane, kickoff)
    }
    private var transport: Transport? = null
    private var generation = 0
    private var requestedCompression = false
    private var lease: String? = null
    private var retiredLease: String? = null
    private var pendingChat: Boolean? = null
    private var runID: String? = null
    private var intent = "ifFree"
    private var choseMode = false
    private var retryJob: Job? = null
    private var suspended = false
    private var rosterTimeout: Job? = null
    private var rosterPolling: Job? = null
    private val releasedPanes = mutableMapOf<String, Int>()
    private var expectedLaunch: Pane? = null
    private var latestDescriptor: Pane? = null
    private var launchExpectation: Job? = null
    internal val leasedPaneID get() = state.value.pane?.id.takeIf { lease != null }
    private val historyGate = HistoryGate()
    private var historyTimeout: Job? = null
    private val pendingCommands = mutableMapOf<String, CompletableDeferred<JsonObject>>()
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
        val host: Host,
        val policy: String?,
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
        rosterTimeout = scope.launch {
            delay(10_000)
            if (attempt == generation) failed("Timed out waiting for the Host")
        }
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
                    if (it.status in setOf(Status.takenOver, Status.hostStopped, Status.paneClosed, Status.incompatible))
                        it.status
                    else Status.disconnected,
                error = reason,
                loadingHistory = false,
            )
        }
        if (
            !suspended &&
                state.value.status == Status.disconnected &&
                state.value.pane == null &&
                !state.value.needsPairing &&
                reason != INVALID_PAIRING_CODE
        ) {
            retryJob =
                scope.launch {
                    delay(5_000)
                    retry()
                }
        }
    }

    private fun detach() {
        rosterTimeout?.cancel()
        rosterTimeout = null
        rosterPolling?.cancel()
        rosterPolling = null
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
        retiredLease = null
        pendingChat = null
        val commands = pendingCommands.values.toList()
        pendingCommands.clear()
        commands.forEach { it.completeExceptionally(IOException("Connection lost before confirmation")) }
        if (state.value.delivery == Delivery.PENDING)
            state.update {
                it.copy(
                    delivery = Delivery.UNKNOWN,
                    hint = "Delivery unconfirmed. Check receipt or Host before sending again.",
                )
            }
    }

    fun close() {
        launchExpectation?.cancel()
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
        if (state.value.status == Status.disconnected && !state.value.needsPairing) retry()
        else if (state.value.status == Status.live) {
            if ("refresh" in state.value.capabilities)
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
        if (!suspended && state.value.status == Status.choosing) send(control("list"))
    }

    internal fun releasePane(id: String) {
        releasedPanes[id] = 2
        state.update { current -> current.copy(panes = current.panes.map {
            if (it.id == id) it.copy(busy = false) else it
        }) }
    }

    private fun mergeDescriptor(pane: Pane): Pane {
        latestDescriptor = pane
        val expected = expectedLaunch?.takeIf { it.id == pane.id } ?: return pane
        if (pane.agent != null) {
            expectedLaunch = null
            launchExpectation?.cancel()
            return pane
        }
        return pane.copy(
            agent = expected.agent, subtitle = expected.subtitle,
            conversation = pane.conversation.takeUnless { it == "unsupported" },
        )
    }

    fun updatePane(pane: Pane) {
        val previous = state.value.pane
        if (previous?.id != pane.id) return
        applyDescriptor(previous, mergeDescriptor(pane))
    }

    private fun applyDescriptor(previous: Pane, pane: Pane) {
        state.update { it.copy(pane = pane) }
        if (!choseMode && previous.conversation != "available" && pane.conversation == "available")
            switchMode(true)
        else if (state.value.chat && pane.conversation == "unsupported") switchMode(false)
    }

    fun choose(pane: Pane, takeover: Boolean = false, kickoff: String? = null, launched: Boolean = false) {
        launchExpectation?.cancel()
        latestDescriptor = null
        expectedLaunch = pane.takeIf { launched && it.agent != null }
        if (expectedLaunch != null) launchExpectation = scope.launch {
            delay(30_000)
            expectedLaunch = null
            val latest = latestDescriptor ?: return@launch
            val current = state.value.pane ?: return@launch
            if (latest.id == current.id) applyDescriptor(current, latest)
        }
        choseMode = false
        pendingChat = null
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
                broughtDraftText = null,
                replacedHostDraft = false,
                submittedText = null,
                keyRefusal = null,
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
        if (current.chat == chat || current.status !in setOf(Status.live, Status.subscribing)) return false
        if (chat && "conversation-v1" !in current.capabilities) return false
        if (current.status == Status.subscribing) {
            // The Host's subscribed reply has no representation. Finish reading its first
            // frame before sending another subscribe so that the reply is unambiguous.
            pendingChat = chat
            state.update { it.copy(kickoff = null) }
            return true
        }
        state.update { it.copy(chat = chat, kickoff = null) }
        intent = "ifFree"
        subscribe()
        return true
    }

    private fun finishModeSwitch() {
        val chat = pendingChat ?: return
        pendingChat = null
        switchMode(chat)
    }

    private fun subscribe() {
        clearScroll()
        val pane = state.value.pane ?: return
        // A History reply may already be on the wire for the lease being replaced.
        if (lease != null) retiredLease = lease
        historyTimeout?.cancel()
        lease = null
        pendingScrollState = null
        val current = state.value
        expectsScrollState = !current.chat && "scroll-state-v1" in current.capabilities
        state.update {
            it.copy(status = Status.subscribing, sequence = 0, scrollBounds = ScrollBounds(),
                screenPrompt = null, loadingHistory = false)
        }
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
        if (!state.value.canAct) return
        state.update { it.copy(actionPending = true, error = null, promptAction = prompt, keyRefusal = null) }
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
                    else it.copy(keyRefusal = message)
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
        if (state.value.hostDraft == null) return
        submission = null
        state.update { it.copy(hostDraft = null, delivery = Delivery.NONE, submittedText = null) }
    }

    fun bringHostDraft(draft: HostDraft) {
        state.update {
            if (it.hostDraft != draft || !draft.complete) it
            else it.copy(
                draft = listOf(draft.text, it.draft.trim()).filter(String::isNotEmpty).joinToString("\n"),
                draftRevision = it.draftRevision + 1,
                hostDraft = null,
                delivery = Delivery.NONE,
                submittedText = null,
                broughtDraftText = draft.text,
                broughtDraftPolicy = when {
                    draft.discardable -> "discard"
                    draft.replaceable -> "replace"
                    else -> null
                },
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
        val item = Submission(uuid(), run, pane.id, current.draft, current.draftRevision, current.host, onDraft)
        submission = item
        state.update {
            it.copy(delivery = Delivery.PENDING, hint = "Sending…", hostDraft = null,
                submittedText = item.text, replacedHostDraft = false)
        }
        scope.launch {
            delay(30_000)
            if (submission == item && state.value.delivery == Delivery.PENDING) state.update {
                it.copy(delivery = Delivery.UNKNOWN, hint = "Delivery unconfirmed. Check Host before sending again.")
            }
        }
        scope.launch {
            try {
                val listing = command(Commands.list())
                if (lease != activeLease || submission != item || state.value.delivery != Delivery.PENDING) return@launch
                val input = Commands.input(listing, item.pane, item.text, onDraft)
                check(!input.has("agentsInput") || "agent-input" in state.value.capabilities) {
                    "Update Host to support interactive Agent input"
                }
                check(!input.has("send") || "shell-send" in state.value.capabilities) {
                    "Host cannot verify an empty command line for remote shell Send. Use an Agent Profile or control the shell on Host"
                }
                send(Commands.request(item.id, input, activeLease))
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
                "launch-profile" in state.value.capabilities &&
                (state.value.status == Status.choosing ||
                    (state.value.status == Status.live && command.keySet().single() in setOf("list", "agentKeys", "promptRespond")))
        ) {
            "Host command unavailable"
        }
        val id = uuid()
        val result = CompletableDeferred<JsonObject>()
        pendingCommands[id] = result
        return try {
            send(Commands.request(id, command, lease))
            withTimeout(30_000) { result.await() }
        } finally {
            pendingCommands.remove(id)
        }
    }

    fun queryReceipt() {
        val s = submission ?: return
        val active = lease ?: return
        if (
            s.runID == runID &&
                sameConfiguration(s.host) &&
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
        require(expectsScrollState &&
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
            if (state.value.status == Status.subscribing && lease == null) return
            require(packet.text.toByteArray().size <= 1024 * 1024) {
                "Text snapshot exceeds capacity"
            }
            require(
                !state.value.chat &&
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
                    status = Status.live,
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
            finishModeSwitch()
            return
        }
        packet as Packet.Control
        val p = packet.payload()
        if (state.value.status == Status.subscribing && lease == null &&
            packet.kind in setOf("conversationSnapshot", "conversationEvents", "scrollState", "screenPrompt")
        ) return
        when (packet.kind) {
            "panes" -> {
                val caps = p.array("capabilities").map { it.asString }.toSet()
                rosterTimeout?.cancel()
                rosterTimeout = null
                if (Wire.DEFLATE in caps && !requestedCompression) {
                    requestedCompression = true
                    send(control("compress"))
                }
                val hostRun = canonical(p.string("hostRunID"))
                val sameRun = runID == hostRun
                runID = hostRun
                val panes = p.array("panes").map {
                    val pane = Pane.parse(it.asJsonObject)
                    val polls = releasedPanes[pane.id] ?: 0
                    if (!pane.busy || polls == 1) releasedPanes.remove(pane.id)
                    else if (polls > 1) releasedPanes[pane.id] = polls - 1
                    if (polls > 0) pane.copy(busy = false) else pane
                }
                releasedPanes.keys.retainAll(panes.mapTo(mutableSetOf(), Pane::id))
                val updatedPane = panes.firstOrNull { pane -> pane.id == state.value.pane?.id }?.let(::mergeDescriptor)
                state.update {
                    it.copy(
                        panes = panes,
                        hostName = p.optionalString("hostName") ?: it.hostName,
                        pane = updatedPane ?: it.pane,
                        capabilities = caps,
                        chat = if (it.status == Status.live) it.chat else
                            it.chat && "conversation-v1" in caps,
                        conversation = if (sameRun) it.conversation else ConversationFeed(),
                        answeredPrompt = it.answeredPrompt.takeIf { sameRun },
                        promptAction = it.promptAction.takeIf { sameRun },
                    )
                }
                if (state.value.pane == null) {
                    val connected = state.value.status != Status.choosing
                    state.update { it.copy(status = Status.choosing) }
                    if (rosterPolling == null) rosterPolling = scope.launch {
                        while (isActive) {
                            delay(3_000)
                            refreshPanes()
                        }
                    }
                    val current = state.value
                    if (current.host.credential != null &&
                        (connected || current.hostName != current.host.hostName)
                    ) {
                        val now = System.currentTimeMillis()
                        val verified = current.host.copy(
                            hostName = current.hostName, lastConnectedAt = now,
                            pairedAt = current.host.pairedAt ?: now,
                        )
                        state.update { it.copy(host = verified) }
                        onRoster?.invoke(this, verified)
                    }
                } else if ("text-v1" !in caps) {
                    state.update { it.copy(status = Status.incompatible) }
                    detach()
                } else if (updatedPane == null) {
                    state.update { it.copy(status = Status.paneClosed) }
                    detach()
                } else if (state.value.status == Status.connecting || !sameRun) {
                    if (!choseMode && "conversation-v1" in caps && state.value.pane?.conversation == "available")
                        state.update { it.copy(chat = true, kickoff = null) }
                    subscribe()
                }
            }
            "subscribed" -> {
                clearScroll()
                pendingScrollState = null
                require(state.value.status == Status.subscribing && lease == null &&
                    canonical(p.string("paneID")) == state.value.pane?.id)
                lease = canonical(p.string("subscriptionID"))
                runID = canonical(p.string("hostRunID"))
                historyTimeout?.cancel()
                historyGate.reset()
                state.update {
                    it.copy(
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
                state.update { it.copy(status = Status.live, conversation = it.conversation.accept(p, snapshot)) }
                if (!events.isEmpty) send(control("acknowledge", obj("subscriptionID" to active, "sequence" to sequence)))
                finishModeSwitch()
            }
            "failure" -> {
                val error = p.string("error")
                if (error.startsWith("CONVERSATION_UNSUPPORTED") && state.value.chat) {
                    state.update { it.copy(chat = false) }
                    subscribe()
                } else if (error.startsWith("SCROLL_UNAVAILABLE") || error.startsWith("SCROLL_BUSY")) {
                    val request = scrollRequest
                    if (request != null &&
                        p.optionalString("subscriptionID")?.let(::canonical) == request.lease &&
                        p.optionalString("requestID")?.let(::canonical) == request.id) {
                        clearScroll()
                        state.update { it.copy(scrollError = error) }
                    }
                } else if (error.startsWith("HISTORY_UNAVAILABLE")) {
                    val replyLease = p.optionalString("subscriptionID")?.let(::canonical)
                    if (replyLease != null && replyLease == retiredLease && replyLease != lease) return
                    if (replyLease == null || replyLease != lease) {
                        failed(error)
                    } else if (state.value.loadingHistory) {
                        historyTimeout?.cancel()
                        state.update { it.copy(error = error, loadingHistory = false) }
                    }
                } else {
                    if (error.startsWith("PANE_BUSY"))
                        state.update { it.copy(status = Status.takenOver) }
                    failed(error)
                }
            }
            "scrollResult" -> scrollResult(p)
            "scrollState" -> receiveScrollState(p)
            "historyPage" -> {
                val replyLease = canonical(p.string("subscriptionID"))
                if (replyLease == retiredLease && replyLease != lease) return
                require(replyLease == lease && state.value.loadingHistory)
                val continuation = historyGate.id != null
                val lines = historyGate.accept(p)
                historyTimeout?.cancel()
                state.update {
                    it.copy(
                        history = if (continuation) lines + it.history else lines,
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
                val pending = pendingCommands.remove(id)
                if (pending != null) pending.complete(result) else delivery(id, result)
            }
            else -> throw IOException("Unexpected Host message: ${packet.kind}")
        }
    }

    private fun sameConfiguration(host: Host) = state.value.host.let {
        it.endpoint == host.endpoint && it.credential == host.credential
    }

    private fun delivery(id: String, response: JsonObject) {
        val s = submission ?: return
        if (s.id != id || !sameConfiguration(s.host) || state.value.delivery !in setOf(Delivery.PENDING, Delivery.UNKNOWN)) return
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
        val recovery = data?.getAsJsonObject("input")?.getAsJsonObject("replaced_draft")?.takeUnless {
            s.policy == "discard" && it.optionalString("text") == state.value.broughtDraftText
        }
        state.update {
            it.copy(
                hostDraft = hostDraft,
                broughtDraftPolicy = it.broughtDraftPolicy.takeUnless { accepted },
                broughtDraftText = it.broughtDraftText.takeUnless { accepted },
                replacedHostDraft = accepted && recovery != null,
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
