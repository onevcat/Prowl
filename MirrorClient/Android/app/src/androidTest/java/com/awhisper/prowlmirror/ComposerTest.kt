package com.awhisper.prowlmirror

import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.*
import org.junit.*
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ComposerTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    @After
    fun close() {
        scope.cancel()
    }

    @Test
    fun doubleHardwareReturnSendsButOneReturnDoesNot() {
        var receive: ((Packet) -> Unit)? = null
        var ready: ((Host) -> Unit)? = null
        val sent = mutableListOf<Packet.Control>()
        val host = Host("test")
        val pane = Pane(uuid(), "Pane", "/tmp", false)
        val session =
            Session(
                host,
                scope,
                TransportFactory { _, _, _, r, a, _ ->
                    receive = r
                    ready = a
                    object : Transport {
                        override fun close() {}

                        override fun send(message: Packet.Control) {
                            sent += message
                        }
                    }
                },
            )
        rule.runOnIdle {
            session.connect()
            ready!!(host)
            receive!!(
                control(
                    "panes",
                    obj(
                        "panes" to listOf(pane),
                        "capabilities" to listOf("text-v1", "launch-profile"),
                        "hostRunID" to uuid(),
                    ),
                )
            )
            session.choose(pane)
            receive!!(
                control(
                    "subscribed",
                    obj("paneID" to pane.id, "subscriptionID" to uuid(), "hostRunID" to uuid()),
                )
            )
        }
        rule.setContent {
            MaterialTheme { Composer(session, session.state.collectAsState().value) }
        }
        rule.onNodeWithTag("composer").performTextInput("hello")
        val time = SystemClock.uptimeMillis()
        fun hardwareReturn(at: Long) {
            rule.runOnIdle {
                for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
                    rule.activity.dispatchKeyEvent(
                        KeyEvent(
                            at,
                            at,
                            action,
                            KeyEvent.KEYCODE_ENTER,
                            0,
                            0,
                            1,
                            0,
                            0,
                            InputDevice.SOURCE_KEYBOARD,
                        )
                    )
                }
            }
        }
        hardwareReturn(time)
        rule.runOnIdle {
            Assert.assertEquals(Delivery.NONE, session.state.value.delivery)
            Assert.assertEquals("hello\n", session.state.value.draft)
        }
        hardwareReturn(time + 100)
        rule.runOnIdle {
            Assert.assertEquals(Delivery.PENDING, session.state.value.delivery)
            Assert.assertEquals("hello", session.state.value.draft)
        }
        session.close()
    }
}
