package com.awhisper.prowlmirror

import com.google.gson.JsonParser
import java.net.InetAddress

internal data class PairingPayload(val address: String, val port: Int, val code: String) {
    companion object {
        fun parse(text: String, nowSeconds: Long = System.currentTimeMillis() / 1000): PairingPayload {
            val invalid = "Scan a Prowl pairing QR code from Add a Device on Host"
            require(text.toByteArray(Charsets.UTF_8).size <= 2048) { invalid }
            val data = try {
                JsonParser.parseString(text).asJsonObject
            } catch (_: Exception) {
                throw IllegalArgumentException(invalid)
            }
            fun string(name: String): String {
                val value = data.get(name)
                require(value != null && value.isJsonPrimitive && value.asJsonPrimitive.isString) { invalid }
                return value.asString
            }
            fun number(name: String): Long {
                val value = data.get(name)
                require(value != null && value.isJsonPrimitive && value.asJsonPrimitive.isNumber) { invalid }
                return value.asString.toLongOrNull() ?: throw IllegalArgumentException(invalid)
            }
            require(string("type") == "prowl-mirror-pairing" && number("version") == 1L) { invalid }
            val address = string("address")
            val port = number("port")
            val code = string("code")
            val expires = number("expiresAt")
            val numericIP = if (':' in address && address.all { it in "0123456789abcdefABCDEF:." }) {
                // The character restriction prevents DNS lookup of scanned host names.
                try { InetAddress.getByName(address) } catch (_: Exception) { null }
            } else if (address.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")) &&
                address.split('.').all { it.toInt() in 0..255 && (it == "0" || !it.startsWith('0')) }) {
                InetAddress.getByAddress(address.split('.').map { it.toInt().toByte() }.toByteArray())
            } else null
            require(numericIP != null && !numericIP.isAnyLocalAddress && !numericIP.isLoopbackAddress &&
                port in 1..65535 && Authentication.code(code) == code && expires > 0) { invalid }
            require(expires > nowSeconds) { "This pairing code expired. Refresh Code on Host and scan again" }
            return PairingPayload(address, port.toInt(), code)
        }
    }
}
