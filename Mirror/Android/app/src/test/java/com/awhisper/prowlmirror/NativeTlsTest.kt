package com.awhisper.prowlmirror

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Optional macOS Network.framework fixture; regular JVM tests do not pretend to cover native TLS.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeTlsTest {
    @Test
    fun networkFrameworkEnrollmentAndDeviceReconnect() {
        val port = System.getenv("MIRROR_NATIVE_TEST_PORT")?.toIntOrNull()
        assumeTrue("Requires the opt-in Network.framework fixture", port != null)
        Dispatchers.setMain(Dispatchers.Default)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val saved = AtomicReference<Host>()
        val failure = AtomicReference<String>()
        val done = CountDownLatch(1)
        var connection: RemoteConnection? = null
        try {
            connection =
                RemoteConnection(
                    Host("127.0.0.1", port!!),
                    "ABCD2345",
                    "Android JVM test",
                    { saved.set(it) },
                    scope,
                    { packet ->
                        if (packet is Packet.Control && packet.kind == "panes") done.countDown()
                    },
                    { verified ->
                        assertNotNull(saved.get()?.credential)
                        assertEquals(verified, saved.get())
                        connection!!.send(control("list"))
                    },
                    { error ->
                        failure.set(error)
                        done.countDown()
                    },
                )
            assertTrue("TLS connection timed out", done.await(15, TimeUnit.SECONDS))
            assertNull(failure.get())
            assertNotNull(saved.get()?.credential)
        } finally {
            connection?.close()
            scope.cancel()
            Dispatchers.resetMain()
        }
    }
}
