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

data class SessionState(
    val host: Host,
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
) {
    val canSend: Boolean
        get() =
            status == Status.live &&
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
) {
    val id = uuid()
    val state = MutableStateFlow(SessionState(host))
    val launch = LaunchModel(scope, ::command, ::choose)
    private var transport: Transport? = null
    private var generation = 0
    private var lease: String? = null
    private var runID: String? = null
    private var intent = "ifFree"
    private var retryJob: Job? = null
    private var retryCount = 0
    private var suspended = false
    private val historyGate = HistoryGate()
    private var historyTimeout: Job? = null
    private var commandPending: Pair<String, CompletableDeferred<JsonObject>>? = null

    private data class Submission(
        val id: String,
        val runID: String,
        val pane: String,
        val text: String,
        val revision: Long,
    )

    private var submission: Submission? = null
    var liveScrollIndex = 0
    var liveScrollOffset = 0
    var historyScrollIndex = 0
    var historyScrollOffset = 0

    fun connect(code: String = "") {
        if (transport != null) return
        retryJob?.cancel()
        val attempt = ++generation
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
    }

    fun foreground() {
        suspended = false
        retryCount = 0
        if (state.value.status == Status.disconnected) retry()
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
        send(control("list"))
    }

    fun choose(pane: Pane, takeover: Boolean = false) {
        submission = null
        historyGate.reset()
        state.update {
            it.copy(
                pane = pane,
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

    private fun subscribe() {
        val pane = state.value.pane ?: return
        lease = null
        state.update { it.copy(status = Status.subscribing, sequence = 0) }
        send(
            control(
                "subscribe",
                obj("paneID" to pane.id, "representation" to "text-v1", "intent" to intent),
            )
        )
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

    fun submit() {
        val current = state.value
        val activeLease = lease ?: return
        val run = runID ?: return
        val pane = current.pane ?: return
        if (!current.canSend) return
        val item = Submission(uuid(), run, pane.id, current.draft, current.draftRevision)
        submission = item
        state.update { it.copy(delivery = Delivery.PENDING, hint = "Host is checking readiness…") }
        scope.launch {
            try {
                val listing = command(Commands.list())
                if (lease != activeLease || submission != item) return@launch
                val input = Commands.input(listing, item.pane, item.text)
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
        if (state.value.loadingHistory || "history" !in state.value.capabilities) return
        if (refresh) {
            historyGate.reset()
            state.update { it.copy(history = emptyList()) }
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

    private fun receive(packet: Packet) {
        if (packet is Packet.Text) {
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
            state.update {
                it.copy(
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
        when (packet.kind) {
            "panes" -> {
                val caps = p.array("capabilities").map { it.asString }.toSet()
                require("text-v1" in caps) { "Update Host to support text mirrors" }
                runID = canonical(p.string("hostRunID"))
                val panes = p.array("panes").map { Pane.parse(it.asJsonObject) }
                state.update { it.copy(panes = panes, capabilities = caps) }
                if (state.value.pane == null) state.update { it.copy(status = Status.choosing) }
                else if (panes.none { it.id == state.value.pane?.id })
                    state.update { it.copy(status = Status.paneClosed) }
                else if (state.value.status != Status.live) subscribe()
            }
            "subscribed" -> {
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
            "failure" -> {
                val error = p.string("error")
                if (
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
                (data?.getAsJsonObject("dispatch")?.optionalString("id") != null ||
                    (response.optionalString("command") == "send" &&
                        data?.getAsJsonObject("input")?.let {
                            it.integer("bytes") == s.text.toByteArray().size &&
                                it.flag("trailing_enter_sent")
                        } == true))
        val error = response.getAsJsonObject("error")
        val rejection =
            error?.optionalString("code")?.takeUnless {
                it in setOf("REMOTE_COMMAND_UNCONFIRMED", "DISPATCH_FAILED", "SEND_FAILED")
            }
        state.update {
            it.copy(
                delivery =
                    if (accepted) Delivery.ACCEPTED
                    else if (rejection != null) Delivery.REJECTED else Delivery.UNKNOWN,
                draft = if (accepted && it.draftRevision == s.revision) "" else it.draft,
                hint =
                    if (accepted) "Dispatched. Agent completion is separate."
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
