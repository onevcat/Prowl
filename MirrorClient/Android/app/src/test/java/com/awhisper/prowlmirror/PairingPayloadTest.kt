package com.awhisper.prowlmirror

import org.junit.Assert.*
import org.junit.Test

class PairingPayloadTest {
    private val valid = """{"type":"prowl-mirror-pairing","version":1,"address":"192.168.1.20","port":7880,"code":"ABCDEFGH","expiresAt":1800000060}"""

    @Test fun readsHostPayloadWithoutSavedCredentials() {
        for (address in listOf("192.168.1.20", "100.64.0.1", "2001:db8::2")) {
            val result = PairingPayload.parse(valid.replace("192.168.1.20", address), 1800000000)
            assertEquals(address, result.address)
            assertEquals(7880, result.port)
            assertEquals("ABCDEFGH", result.code)
        }
    }

    @Test fun rejectsExpiredOrInvalidPayloads() {
        val bad = listOf(
            "https://example.com", "{}", "x".repeat(2049),
            valid.replace("1800000060", "1800000000"),
            valid.replace("\"version\":1", "\"version\":2"),
            valid.replace("7880", "0"), valid.replace("7880", "65536"),
            valid.replace("7880", "\"7880\""), valid.replace("ABCDEFGH", "invalid"),
            valid.replace("192.168.1.20", "example.com"),
            valid.replace("192.168.1.20", "127.0.0.1"),
            valid.replace("192.168.1.20", "0:0:0:0:0:0:0:1"),
            valid.replace("192.168.1.20", "::ffff:127.0.0.1"),
        )
        for (text in bad) assertThrows(IllegalArgumentException::class.java) {
            PairingPayload.parse(text, 1800000000)
        }
    }
}
