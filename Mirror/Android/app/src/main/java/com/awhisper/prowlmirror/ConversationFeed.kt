package com.awhisper.prowlmirror

import com.google.gson.JsonObject

data class ConversationEvent(val sequence: Long, val kind: String, val source: String, val data: JsonObject) {
    companion object {
        fun parse(json: JsonObject) = ConversationEvent(
            json.longInteger("seq"),
            json.string("kind"),
            json.string("source"),
            json.record("data"),
        )
    }
}

data class ConversationFeed(
    val sequence: Long = 0,
    val events: List<ConversationEvent> = emptyList(),
    val gap: Boolean = false,
) {
    val openPrompt: JsonObject?
        get() = events.asReversed().firstOrNull {
            it.kind in setOf("session.changed", "session.pending", "session.ended") ||
                (it.source == "screen" && it.kind in setOf("prompt.opened", "prompt.resolved"))
        }?.takeIf { it.kind == "prompt.opened" }?.data

    val agentState: String?
        get() = events.lastOrNull { it.kind == "agent.status" }?.data?.optionalString("state")

    fun accept(packet: JsonObject, snapshot: Boolean): ConversationFeed {
        val end = packet.longInteger("sequence")
        val batch = packet.array("events")
        require(batch.size() <= MAX_EVENTS && end >= sequence) { "Invalid conversation batch" }
        val missing = snapshot && packet.flag("gap")
        val incoming = batch.map { ConversationEvent.parse(it.asJsonObject) }
        var previous = sequence
        for (event in incoming) {
            require(event.sequence > previous) { "Invalid conversation sequence" }
            if (!snapshot || (previous > 0 && !missing))
                require(event.sequence == previous + 1) { "Missing conversation events" }
            previous = event.sequence
        }
        require(incoming.isEmpty() || previous == end) { "Conversation sequence does not match the batch" }

        val combined = events + incoming
        return ConversationFeed(end, combined.takeLast(MAX_EVENTS), missing || gap || combined.size > MAX_EVENTS)
    }

    companion object {
        const val MAX_EVENTS = 2_000
    }
}
