package com.awhisper.prowlmirror

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.bouncycastle.tls.*
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto

data class Credential(val hostID: String, val deviceID: String, val key: String)

data class Host(val address: String, val port: Int = 5988, val credential: Credential? = null) {
    val endpoint: String
        get() = "$address:$port"
}

object Authentication {
    fun code(raw: String): String {
        val normalized = raw.uppercase().filterNot { it.isWhitespace() || it == '-' }
        require(
            normalized.length == 8 && normalized.all { it in "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" }
        ) {
            "Enter the current 8-character Host code"
        }
        return normalized
    }

    fun proof(
        key: ByteArray,
        host: String,
        nonce: ByteArray,
        purpose: String,
        identity: String,
    ): String {
        require(nonce.size == 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return Base64.getEncoder()
            .encodeToString(
                mac.doFinal("$purpose:${canonical(host)}:$identity:".toByteArray() + nonce)
            )
    }
}

interface Transport {
    fun send(message: Packet.Control)

    fun close()
}

fun interface TransportFactory {
    fun connect(
        host: Host,
        code: String,
        scope: CoroutineScope,
        receive: (Packet) -> Unit,
        ready: (Host) -> Unit,
        closed: (String) -> Unit,
    ): Transport
}

class RemoteConnection(
    private var host: Host,
    private val code: String,
    private val name: String,
    private val persist: (Host) -> Unit,
    private val scope: CoroutineScope,
    private val receive: (Packet) -> Unit,
    private val ready: (Host) -> Unit,
    private val closed: (String) -> Unit,
) : Transport {
    @Volatile private var stopped = false
    @Volatile private var socket: Socket? = null
    private val outbound = Channel<Packet.Control>(32)
    private val job =
        scope.launch(Dispatchers.IO) {
            try {
                runConnection()
            } catch (error: Exception) {
                if (!stopped)
                    withContext(Dispatchers.Main) { closed(error.message ?: "Connection lost") }
            } finally {
                socket?.close()
                outbound.close()
            }
        }

    override fun send(message: Packet.Control) {
        if (!stopped && outbound.trySend(message).isFailure) {
            scope.launch { closed("Connection cannot keep up; reconnect") }
            close()
        }
    }

    override fun close() {
        stopped = true
        socket?.close()
        job.cancel()
        outbound.close()
    }

    private suspend fun runConnection() {
        while (!stopped) {
            val credential = host.credential
            val key =
                credential?.let {
                    Base64.getDecoder().decode(it.key).also { bytes -> require(bytes.size == 32) }
                } ?: Authentication.code(code).toByteArray()
            val identity = credential?.let { canonical(it.deviceID) } ?: "pair"
            val next = Socket()
            socket = next
            next.connect(InetSocketAddress(host.address, host.port), 5_000)
            next.soTimeout = 5_000
            next.tcpNoDelay = true
            val tls = TlsClientProtocol(next.getInputStream(), next.getOutputStream())
            tls.connect(
                object : PSKTlsClient(BcTlsCrypto(SecureRandom()), identity.toByteArray(), key) {
                    override fun getSupportedVersions(): Array<ProtocolVersion> =
                        arrayOf(ProtocolVersion.TLSv12)

                    override fun getSupportedCipherSuites(): IntArray =
                        intArrayOf(CipherSuite.TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256)
                }
            )
            val input = tls.inputStream
            val output = tls.outputStream
            fun write(packet: Packet.Control) {
                output.write(Wire.encode(packet))
                output.flush()
            }
            fun readControl(): Packet.Control {
                while (true) {
                    val packet =
                        Wire.read(input) as? Packet.Control
                            ?: throw IOException("Authentication expected")
                    when (packet.kind) {
                        "ping" -> write(control("pong"))
                        "pong" -> Unit
                        "failure" -> throw IOException(packet.payload().string("error"))
                        else -> return packet
                    }
                }
            }
            val challenge = readControl()
            require(challenge.kind == "challenge") { "Host authentication failed" }
            val hostID = canonical(challenge.payload().string("hostID"))
            val nonce = Base64.getDecoder().decode(challenge.payload().string("nonce"))
            if (credential != null && canonical(credential.hostID) != hostID)
                throw IOException("Host identity changed. Pair again.")
            val purpose = if (credential == null) "pair" else "device"
            val who = if (credential == null) name else canonical(credential.deviceID)
            val proof = Authentication.proof(key, hostID, nonce, purpose, who)
            write(
                if (credential == null) control("pair", obj("name" to name, "proof" to proof))
                else control("authenticate", obj("deviceID" to who, "proof" to proof))
            )
            val response = readControl()
            if (credential == null) {
                require(response.kind == "paired") { "Pairing failed or expired" }
                val payload = response.payload()
                val enrolled =
                    Credential(
                        canonical(payload.string("hostID")),
                        canonical(payload.string("deviceID")),
                        payload.string("key"),
                    )
                require(
                    enrolled.hostID == hostID && Base64.getDecoder().decode(enrolled.key).size == 32
                ) {
                    "Invalid device credential"
                }
                host = host.copy(credential = enrolled)
                persist(host)
                next.close()
                continue
            }
            require(
                response.kind == "authenticated" && canonical(response.value!!.asString) == hostID
            ) {
                "Device authentication failed"
            }
            persist(host)
            next.soTimeout = 8_000
            withContext(Dispatchers.Main) { ready(host) }
            coroutineScope {
                val writer = launch(Dispatchers.IO) { for (message in outbound) write(message) }
                val heartbeat = launch {
                    while (isActive) {
                        delay(2_000)
                        outbound.send(control("ping"))
                    }
                }
                try {
                    while (isActive && !stopped) {
                        val packet = Wire.read(input)
                        if (packet is Packet.Control && packet.kind == "ping")
                            outbound.send(control("pong"))
                        else if (!(packet is Packet.Control && packet.kind == "pong"))
                            withContext(Dispatchers.Main) { receive(packet) }
                    }
                } finally {
                    writer.cancel()
                    heartbeat.cancel()
                }
            }
            return
        }
    }
}
