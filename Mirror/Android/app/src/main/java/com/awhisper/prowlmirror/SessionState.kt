package com.awhisper.prowlmirror

import com.google.gson.JsonObject
import java.io.IOException

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

internal const val HOST_BUSY = "The Mac is still finishing the previous request. Try again in a moment."
internal const val HISTORY_TIMED_OUT = "History timed out. Retry history."

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

class ReadingPositions {
    var chatVisibleLimit = CHAT_PAGE
    var chatScrollIndex = 0
    var chatScrollOffset = 0
    var chatFollowsLatest = true
    var liveScrollIndex = 0
    var liveScrollOffset = 0
    var historyScrollIndex = 0
    var historyScrollOffset = 0
}
