package com.awhisper.prowlmirror

import com.google.gson.*
import java.io.*
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

fun uuid(): String = UUID.randomUUID().toString().uppercase()

fun canonical(value: String): String = UUID.fromString(value).toString().uppercase()

fun obj(vararg pairs: Pair<String, Any?>): JsonObject =
    JsonObject().apply {
        pairs.forEach { (key, value) -> if (value != null) add(key, Gson().toJsonTree(value)) }
    }

fun JsonObject.string(key: String): String =
    get(key)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString
        ?: throw IOException("Missing or invalid $key")

fun JsonObject.record(key: String): JsonObject =
    get(key)?.takeIf { it.isJsonObject }?.asJsonObject
        ?: throw IOException("Missing or invalid $key")

fun JsonObject.array(key: String): JsonArray =
    get(key)?.takeIf { it.isJsonArray }?.asJsonArray ?: throw IOException("Missing or invalid $key")

fun JsonObject.flag(key: String): Boolean =
    get(key)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }?.asBoolean
        ?: throw IOException("Missing or invalid $key")

fun JsonObject.optionalString(key: String): String? =
    if (!has(key) || get(key).isJsonNull) null else string(key)

fun JsonObject.integer(key: String): Int =
    stringNumber(key).toIntOrNull() ?: throw IOException("Invalid $key")

private fun JsonObject.stringNumber(key: String): String =
    get(key)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isNumber }?.asString
        ?: throw IOException("Invalid $key")

data class Pane(
    val id: String,
    val title: String,
    val directory: String,
    val busy: Boolean,
    val projectName: String? = null,
    val subtitle: String? = null,
) {
    val label: String
        get() = projectName ?: title

    companion object {
        fun parse(o: JsonObject) =
            Pane(
                canonical(o.string("id")),
                o.string("title"),
                o.string("directory"),
                o.flag("busy"),
                o.optionalString("projectName"),
                o.optionalString("subtitle"),
            )
    }
}

sealed interface Packet {
    data class Control(val kind: String, val value: JsonElement? = null) : Packet {
        fun payload(): JsonObject =
            value?.takeIf { it.isJsonObject }?.asJsonObject
                ?: throw IOException("Invalid $kind payload")
    }

    data class Text(
        val lease: String,
        val sequence: Long,
        val columns: Int,
        val rows: Int,
        val truncated: Boolean,
        val text: String,
    ) : Packet
}

object Wire {
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    const val MAX_INPUT = 64 * 1024
    private val controls =
        setOf(
            "challenge",
            "authenticate",
            "pair",
            "paired",
            "authenticated",
            "list",
            "panes",
            "subscribe",
            "subscribed",
            "acknowledge",
            "input",
            "refresh",
            "history",
            "historyPage",
            "command",
            "commandResult",
            "commandReceipt",
            "failure",
            "ended",
            "ping",
            "pong",
        )
    private val empty = setOf("list", "ping", "pong")

    fun encode(packet: Packet.Control): ByteArray {
        require(packet.kind in controls)
        val body =
            if (packet.kind in empty) obj(packet.kind to obj())
            else obj(packet.kind to obj("_0" to packet.value))
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size + 1 <= MAX_PAYLOAD)
        return ByteBuffer.allocate(bytes.size + 5).putInt(bytes.size + 1).put(0).put(bytes).array()
    }

    fun read(input: InputStream): Packet {
        val stream = DataInputStream(input)
        val length = stream.readInt()
        if (length !in 1..MAX_PAYLOAD) throw IOException("Invalid mirror packet length")
        val bytes = ByteArray(length)
        stream.readFully(bytes)
        return decode(bytes)
    }

    fun decode(bytes: ByteArray): Packet {
        if (bytes.isEmpty() || bytes.size > MAX_PAYLOAD) throw IOException("Invalid packet size")
        if (bytes[0].toInt() == 0) {
            val root = JsonParser.parseString(utf8(bytes.copyOfRange(1, bytes.size))).asJsonObject
            if (root.size() != 1) throw IOException("Invalid control envelope")
            val kind = root.keySet().single()
            if (kind !in controls) throw IOException("Unsupported mirror protocol")
            val container = root.record(kind)
            if (kind in empty) return Packet.Control(kind)
            return Packet.Control(
                kind,
                container.get("_0") ?: throw IOException("Missing control payload"),
            )
        }
        // Android is a text client; accepting terminal packets would hide a representation
        // mismatch.
        if (bytes[0].toInt() != 2 || bytes.size < 34)
            throw IOException("Expected a text mirror frame")
        val b = ByteBuffer.wrap(bytes)
        b.get()
        val lease = UUID(b.long, b.long).toString().uppercase()
        val sequence = b.long
        val columns = b.int
        val rows = b.int
        val flag = b.get().toInt()
        if (sequence <= 0 || columns !in 0..1000 || rows !in 0..1000 || flag !in 0..1)
            throw IOException("Invalid text frame")
        val text = ByteArray(b.remaining())
        b.get(text)
        return Packet.Text(lease, sequence, columns, rows, flag == 1, utf8(text))
    }

    private fun utf8(bytes: ByteArray): String =
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
}

fun control(kind: String, payload: JsonElement? = null) = Packet.Control(kind, payload)

object Commands {
    fun request(id: String, command: JsonObject, lease: String?) =
        control(
            "command",
            obj(
                "subscriptionID" to lease,
                "commandRequest" to
                    obj(
                        "requestID" to id,
                        "request" to obj("output" to "json", "command" to command),
                    ),
            ),
        )

    fun list() = obj("list" to obj("_0" to obj()))

    fun profiles() = obj("profiles" to obj("_0" to obj()))

    fun create(worktree: String, profile: String, prompt: String) =
        obj(
            "create" to
                obj(
                    "_0" to
                        obj(
                            "resource" to "tab",
                            "selector" to obj("worktree" to obj("_0" to worktree)),
                            "launch" to
                                obj(
                                    "profile" to profile,
                                    "prompt" to prompt.takeIf { it.isNotBlank() },
                                ),
                            "background" to true,
                        )
                )
        )

    fun input(listing: JsonObject, pane: String, text: String): JsonObject {
        if (!listing.flag("ok")) throw IOException("Host could not verify the target")
        val item =
            listing
                .record("data")
                .array("items")
                .map { it.asJsonObject }
                .firstOrNull { canonical(it.record("pane").string("id")) == pane }
                ?: throw IOException("Pane is no longer available")
        if (item.record("pane").optionalString("agent") != null)
            return obj("agentsDispatch" to obj("_0" to obj("pane" to pane, "prompt" to text)))
        if (item.record("task").optionalString("status") != "idle")
            throw IOException("Shell is busy or its state is unknown")
        return obj(
            "send" to
                obj(
                    "_0" to
                        obj(
                            "selector" to obj("pane" to obj("_0" to pane)),
                            "text" to text,
                            "trailing_enter" to true,
                            "source" to "argv",
                            "wait" to false,
                            "capture_output" to false,
                        )
                )
        )
    }
}
