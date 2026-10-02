package com.awhisper.prowlmirror

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class CoreTest {
    @Test
    fun defaultPortMatchesHostAndPreservesCustomPort() {
        assertEquals(7880, Host("host").port)
        assertEquals(9000, Host("host", 9000).port)
    }

    @Test
    fun fixedTextVectorAndReplacement() {
        val raw =
            byteArrayOf(2) +
                ByteArray(16) { it.toByte() } +
                ByteBuffer.allocate(8).putLong(1).array() +
                byteArrayOf(0, 0, 0, 80, 0, 0, 0, 24, 1, 65)
        val frame = Wire.decode(raw) as Packet.Text
        assertEquals("00010203-0405-0607-0809-0A0B0C0D0E0F", frame.lease)
        assertEquals("A", frame.text)
        assertTrue(frame.truncated)
        assertEquals(80, frame.columns)
        assertEquals("", (Wire.decode(raw.dropLast(1).toByteArray()) as Packet.Text).text)
        val packet = ByteBuffer.allocate(4).putInt(raw.size).array() + raw
        assertEquals(frame, Wire.read(ByteArrayInputStream(packet)))
    }

    @Test
    fun invalidWireFailsClosed() {
        listOf(
                byteArrayOf(),
                byteArrayOf(9),
                byteArrayOf(2, 1),
                byteArrayOf(0) + "{\"textFrame\":{}}".toByteArray(),
                byteArrayOf(0) + "{\"subscribed\":{}}".toByteArray(),
            )
            .forEach { bytes -> assertThrows(Exception::class.java) { Wire.decode(bytes) } }
        assertThrows(Exception::class.java) {
            Wire.read(ByteArrayInputStream(byteArrayOf(127, -1, -1, -1)))
        }
        val invalid =
            byteArrayOf(2) +
                ByteArray(16) +
                ByteBuffer.allocate(8).putLong(1).array() +
                ByteArray(9) +
                byteArrayOf(-1)
        assertThrows(Exception::class.java) { Wire.decode(invalid) }
    }

    @Test
    fun swiftControlShape() {
        val encoded = Wire.encode(control("list"))
        assertEquals("{\"list\":{}}", String(encoded.drop(5).toByteArray()))
        val id = uuid()
        val packet = Commands.request(id, Commands.list(), null)
        val request = packet.payload().record("commandRequest").record("request")
        assertEquals("json", request.string("output"))
        assertEquals(0, request.record("command").record("list").record("_0").size())
    }

    @Test
    fun scrollControlsUseSwiftEnvelopeAndStrictSequenceNumbers() {
        val requestID = "00010203-0405-0607-0809-0A0B0C0D0E0F"
        val lease = "11111111-2222-3333-4444-555555555555"
        val encoded = Wire.encode(control("scroll", obj(
            "requestID" to requestID, "direction" to "up", "subscriptionID" to lease,
        )))
        assertEquals(
            "{\"scroll\":{\"_0\":{\"requestID\":\"$requestID\",\"direction\":\"up\",\"subscriptionID\":\"$lease\"}}}",
            String(encoded.drop(5).toByteArray()),
        )
        val result = Wire.read(ByteArrayInputStream(Wire.encode(control("scrollResult", obj(
            "requestID" to requestID, "sequence" to Long.MAX_VALUE, "subscriptionID" to lease,
        ))))) as Packet.Control
        assertEquals("scrollResult", result.kind)
        assertEquals(Long.MAX_VALUE, result.payload().longInteger("sequence"))
        for (invalid in listOf("1", 1.5, java.math.BigInteger("9223372036854775808"))) {
            assertThrows(Exception::class.java) { obj("sequence" to invalid).longInteger("sequence") }
        }
    }

    @Test
    fun scrollStateUsesSwiftEnvelopeAndStrictOptionalBounds() {
        val lease = "11111111-2222-3333-4444-555555555555"
        val packet = control("scrollState", obj(
            "atTop" to true, "atBottom" to false, "sequence" to 12, "subscriptionID" to lease,
        ))
        val encoded = Wire.encode(packet)
        assertEquals(
            "{\"scrollState\":{\"_0\":{\"atTop\":true,\"atBottom\":false,\"sequence\":12,\"subscriptionID\":\"$lease\"}}}",
            String(encoded.drop(5).toByteArray()),
        )
        val payload = (Wire.read(ByteArrayInputStream(encoded)) as Packet.Control).payload()
        assertEquals(true, payload.optionalFlag("atTop"))
        assertEquals(false, payload.optionalFlag("atBottom"))
        assertNull(payload.optionalFlag("missing"))
        payload.add("atTop", com.google.gson.JsonNull.INSTANCE)
        assertNull(payload.optionalFlag("atTop"))
        assertThrows(Exception::class.java) { obj("atTop" to "true").optionalFlag("atTop") }
        assertThrows(Exception::class.java) { obj("atTop" to 1).optionalFlag("atTop") }
    }

    @Test
    fun pairingAndProofBinding() {
        assertEquals("ABCD2345", Authentication.code("abcd-2345"))
        assertThrows(Exception::class.java) { Authentication.code("0OIL1111") }
        assertThrows(Exception::class.java) { Authentication.code("a".repeat(64)) }
        val host = uuid()
        val key = ByteArray(32) { 1 }
        val nonce = ByteArray(32) { 2 }
        val proof = Authentication.proof(key, host, nonce, "device", "name")
        assertNotEquals(proof, Authentication.proof(key, host, nonce, "pair", "name"))
        assertNotEquals(proof, Authentication.proof(key, uuid(), nonce, "device", "name"))
        assertNotEquals(proof, Authentication.proof(key, host, ByteArray(32), "device", "name"))
    }

    @Test
    fun historyContinuityAndFrozenIdentity() {
        val gate = HistoryGate()
        val id = uuid()
        fun page(offset: Int, lines: List<String>, time: Double = 4.0) =
            obj(
                "historyID" to id,
                "offset" to offset,
                "total" to 3,
                "capturedAt" to time,
                "lines" to lines,
            )
        assertEquals(listOf("b", "c"), gate.accept(page(1, listOf("b", "c"))))
        assertThrows(Exception::class.java) { gate.accept(page(0, listOf("a"), 5.0)) }
        assertEquals(listOf("a"), gate.accept(page(0, listOf("a"))))
        assertThrows(Exception::class.java) { gate.accept(page(0, listOf("a"))) }
    }

    @Test
    fun shellAndAgentUsePublicRoutes() {
        val pane = uuid()
        fun listing(agent: String?, status: String?) =
            obj(
                "ok" to true,
                "data" to
                    obj(
                        "items" to
                            listOf(
                                obj(
                                    "pane" to obj("id" to pane, "agent" to agent),
                                    "task" to obj("status" to status),
                                )
                            )
                    ),
            )
        assertTrue(
            Commands.input(listing("claude", "running"), pane, "hello").has("agentsInput")
        )
        assertTrue(Commands.input(listing(null, "idle"), pane, "hello").has("send"))
        assertThrows(Exception::class.java) { Commands.input(listing(null, "running"), pane, "x") }
        assertThrows(Exception::class.java) { Commands.input(listing(null, null), pane, "x") }
    }

    @Test
    fun doubleReturnPreservesIntentionalWhitespace() {
        val gesture = DoubleReturn()
        gesture.record("hi\n\n", 4, 100)
        assertEquals("hi\n", gesture.consume("hi\n\n", 4, 400))
        gesture.record("hi\n", 3, 100)
        assertNull(gesture.consume("hi\n", 3, 451))
        gesture.record("hi\n", 3, 100)
        gesture.validate("changed", 3)
        assertNull(gesture.consume("hi\n", 3, 200))
    }

    @Test
    fun documentCodeTableAndUnicode() {
        val blocks =
            Document.blocks("hello\n```swift\nlet x = 1\n```\n| A | B |\n| --- | --- |\n| x | y |")
        assertTrue(blocks.any { it is Block.Code })
        assertTrue(blocks.any { it is Block.Table })
        val text = "x".repeat(4095) + "😀" + "y".repeat(4096)
        assertEquals(text, Document.blocks(text).joinToString("") { it.raw })
        assertTrue(Document.blocks(text).all { it.raw.length <= 4096 })
    }
}
