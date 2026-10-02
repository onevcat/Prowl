package com.awhisper.prowlmirror

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemoteScrollTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var session: Session
    private lateinit var receive: (Packet) -> Unit
    private lateinit var ready: (Host) -> Unit
    private val sent = mutableListOf<Packet.Control>()
    private val lease = uuid()
    private var sequence = 1L
    private var includesScrollState = false
    private val compositionGeneration = mutableStateOf(0)

    @After
    fun close() {
        rule.runOnIdle {
            if (::session.isInitialized) session.close()
            scope.cancel()
        }
    }

    private fun show(
        text: String = "Current viewport\nReady for remote scrolling.",
        capability: Boolean = true,
        scrollState: Boolean = false,
    ) {
        includesScrollState = scrollState
        val host = Host("test-host")
        val pane = Pane(uuid(), "Scroll test", "/test", false)
        val run = uuid()
        lateinit var model: MirrorModel
        rule.runOnIdle {
            session = Session(host, scope, TransportFactory { _, _, _, r, a, _, _ ->
                receive = r
                ready = a
                object : Transport {
                    override fun close() {}
                    override fun send(message: Packet.Control) { sent += message }
                }
            })
            session.connect()
            ready(host)
            receive(control("panes", obj(
                "panes" to listOf(pane),
                "capabilities" to listOfNotNull(
                    "text-v1", "history", "remote-scroll".takeIf { capability },
                    "scroll-state-v1".takeIf { scrollState },
                ),
                "hostRunID" to run,
            )))
            session.choose(pane)
            receive(control("subscribed", obj(
                "paneID" to pane.id, "subscriptionID" to lease, "hostRunID" to run,
            )))
            if (includesScrollState) bounds(sequence)
            receive(Packet.Text(lease, sequence, 80, 24, false, text))
            session.setFollow(false)
            model = MirrorModel(rule.activity.application)
            model.sessions += session
            model.selected = session.id
        }
        rule.setContent { key(compositionGeneration.value) { MirrorApp(model) } }
    }

    private fun bounds(sequence: Long, atTop: Boolean? = null, atBottom: Boolean? = null) {
        receive(control("scrollState", obj(
            "subscriptionID" to lease, "sequence" to sequence,
            "atTop" to atTop, "atBottom" to atBottom,
        )))
    }

    private fun complete(text: String = session.state.value.text) {
        rule.runOnIdle {
            val request = sent.last { it.kind == "scroll" }.payload()
            if (includesScrollState) bounds(sequence + 1)
            receive(Packet.Text(lease, ++sequence, 80, 24, false, text))
            receive(control("scrollResult", obj(
                "subscriptionID" to lease,
                "requestID" to request.string("requestID"),
                "sequence" to sequence,
            )))
        }
        rule.waitForIdle()
    }

    private fun screenshot(name: String) {
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "scroll-tests")
        directory.mkdirs()
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test
    fun buttonsShowLoadingAndUnchangedFrameFinishesWithoutDisconnect() {
        show()
        val outputBounds = rule.onNodeWithTag("mirror-output").fetchSemanticsNode().boundsInRoot
        val upBounds = rule.onNodeWithText("Scroll up").fetchSemanticsNode().boundsInRoot
        val followBounds = rule.onNodeWithText("Follow latest").fetchSemanticsNode().boundsInRoot
        val downBounds = rule.onNodeWithText("Scroll down").fetchSemanticsNode().boundsInRoot
        assertTrue(upBounds.left <= outputBounds.left + outputBounds.width * 0.2f)
        assertTrue(downBounds.right >= outputBounds.right - outputBounds.width * 0.2f)
        assertTrue(downBounds.left - upBounds.right > outputBounds.width * 0.4f)
        assertTrue(upBounds.bottom <= outputBounds.top)
        assertTrue(followBounds.top >= outputBounds.bottom)
        rule.onNodeWithText("Scroll up").assertIsEnabled().performClick()
        rule.onNodeWithText("Scroll up").assertIsNotEnabled()
        rule.onNodeWithText("Scroll down").assertIsNotEnabled()
        rule.onNodeWithText("Loading…").assertIsDisplayed()
        assertEquals(upBounds, rule.onNodeWithText("Scroll up").fetchSemanticsNode().boundsInRoot)
        assertEquals(downBounds, rule.onNodeWithText("Scroll down").fetchSemanticsNode().boundsInRoot)
        screenshot("loading")
        rule.runOnIdle {
            assertEquals(1, sent.count { it.kind == "scroll" })
            assertFalse(session.state.value.follow)
        }
        complete()
        rule.onNodeWithText("Loading…").assertDoesNotExist()
        rule.onNodeWithText("Scroll down").assertIsEnabled().performClick()
        complete("Later viewport\nRemote scroll completed.")
        rule.onNodeWithText("Later viewport\nRemote scroll completed.").assertIsDisplayed()
        rule.runOnIdle {
            assertEquals(listOf("up", "down"), sent.filter { it.kind == "scroll" }.map { it.payload().string("direction") })
            assertEquals(Status.live, session.state.value.status)
        }
        screenshot("completed")
    }

    @Test
    fun hostBoundsDisableOnlyTheirDirectionAndRestoreOnNewFrames() {
        show(scrollState = true)
        rule.onNodeWithText("Scroll up").assertIsEnabled()
        rule.onNodeWithText("Scroll down").assertIsEnabled()
        rule.runOnIdle { bounds(sequence + 1, atTop = true, atBottom = false) }
        rule.onNodeWithText("Scroll up").assertIsEnabled()
        rule.runOnIdle {
            receive(Packet.Text(lease, ++sequence, 80, 24, false, session.state.value.text))
        }
        rule.onNodeWithText("Scroll up").assertIsNotEnabled()
        rule.onNodeWithText("Scroll down").assertIsEnabled()
        screenshot("at-top")
        rule.runOnIdle {
            bounds(sequence + 1, atTop = false, atBottom = true)
            receive(Packet.Text(lease, ++sequence, 80, 24, false, session.state.value.text))
        }
        rule.onNodeWithText("Scroll up").assertIsEnabled()
        rule.onNodeWithText("Scroll down").assertIsNotEnabled()
        screenshot("at-bottom")
        rule.runOnIdle {
            bounds(sequence + 1)
            receive(Packet.Text(lease, ++sequence, 80, 24, false, session.state.value.text))
        }
        rule.onNodeWithText("Scroll down").assertIsEnabled()
        rule.onNodeWithText("Scroll up").assertIsEnabled().performClick()
        complete()
        rule.onNodeWithText("Scroll up").assertIsEnabled()
        rule.runOnIdle { assertEquals(1, sent.count { it.kind == "scroll" }) }
    }

    @Test
    fun edgePullsAndHorizontalGesturesNeverScrollTheRemotePane() {
        show()
        val output = rule.onNodeWithTag("mirror-output")
        output.performTouchInput { swipe(Offset(width * .8f, height * .5f), Offset(width * .2f, height * .5f)) }
        output.performTouchInput { swipeDown() }
        output.performTouchInput { swipeUp() }
        rule.runOnIdle { assertEquals(0, sent.count { it.kind == "scroll" }) }
        rule.onNodeWithText("Scroll up").assertIsEnabled()
        rule.onNodeWithText("Scroll down").assertIsEnabled()
    }

    @Test
    fun longPressDragDoesNotScrollTheRemotePane() {
        show()
        rule.onNodeWithTag("mirror-output").performTouchInput {
            down(Offset(width * .3f, 80f))
            advanceEventTime(700)
            moveTo(Offset(width * .3f, 330f))
            up()
        }
        rule.runOnIdle { assertEquals(0, sent.count { it.kind == "scroll" }) }
    }

    @Test
    fun nativeTextScrollingRemainsLocalAndRemoteCompletionAnchorsCorrectly() {
        val text = (1..140).joinToString("\n") { "Terminal row $it" }
        show(text)
        val output = rule.onNodeWithTag("mirror-output")
        output.performTouchInput { swipeUp() }
        rule.runOnIdle {
            assertEquals(0, sent.count { it.kind == "scroll" })
            assertTrue(session.liveScrollIndex > 0 || session.liveScrollOffset > 0)
        }
        rule.onNodeWithText("Scroll up").performClick()
        complete(text)
        rule.runOnIdle {
            assertEquals(0, session.liveScrollIndex)
            assertEquals(0, session.liveScrollOffset)
        }
        output.performTouchInput { swipeUp() }
        rule.runOnIdle { assertTrue(session.liveScrollIndex > 0 || session.liveScrollOffset > 0) }
        rule.onNodeWithText("Scroll down").performClick()
        complete(text)
        rule.runOnIdle {
            assertEquals(0, session.liveScrollIndex)
            assertEquals(0, session.liveScrollOffset)
        }
        screenshot("local-reading")
        rule.onNodeWithText("Follow latest").performClick()
        rule.onNodeWithText("Following latest").assertIsDisplayed()
        rule.runOnIdle {
            assertTrue(session.state.value.follow)
            assertEquals(2, sent.count { it.kind == "scroll" })
        }
    }

    @Test
    fun rebuildingReaderDoesNotReplayCompletedRemoteScroll() {
        val text = (1..140).joinToString("\n") { "Terminal row $it" }
        show(text)
        rule.onNodeWithText("Scroll up").performClick()
        complete(text)
        rule.onNodeWithTag("mirror-output").performTouchInput { swipeUp() }
        var position = 0 to 0
        rule.runOnIdle {
            position = session.liveScrollIndex to session.liveScrollOffset
            assertTrue(position.first > 0 || position.second > 0)
            compositionGeneration.value++
        }
        rule.waitForIdle()
        rule.runOnIdle {
            assertEquals(position, session.liveScrollIndex to session.liveScrollOffset)
        }
    }

    @Test
    fun oldHostsHaveNoRemoteControlsOrRemoteGestures() {
        show(capability = false)
        rule.onNodeWithText("Scroll up").assertDoesNotExist()
        rule.onNodeWithText("Scroll down").assertDoesNotExist()
        rule.onNodeWithTag("mirror-output").performTouchInput { swipeDown() }
        rule.runOnIdle { assertEquals(0, sent.count { it.kind == "scroll" }) }
    }

    @Test
    fun historyKeepsItsOwnScrollingOnHostsThatSupportRemoteScrolling() {
        show()
        rule.onNodeWithContentDescription("History").performClick()
        rule.runOnIdle {
            receive(control("historyPage", obj(
                "subscriptionID" to lease, "historyID" to uuid(), "offset" to 0,
                "total" to 2, "capturedAt" to 1.0, "truncated" to false,
                "lines" to listOf("Frozen history", "Still available"),
            )))
        }
        rule.onNodeWithText("Frozen history\nStill available").assertIsDisplayed()
        rule.onNodeWithText("Scroll up").assertDoesNotExist()
        rule.onNodeWithText("Scroll down").assertDoesNotExist()
        rule.onNodeWithText("Load earlier").assertIsNotEnabled()
        rule.onNodeWithTag("mirror-output").performTouchInput { swipeDown() }
        rule.runOnIdle { assertEquals(0, sent.count { it.kind == "scroll" }) }
        screenshot("history")
        rule.onNodeWithText("Back to Live").performClick()
        rule.onNodeWithText("Current viewport\nReady for remote scrolling.").assertIsDisplayed()
    }

    @Test
    fun unavailableEndsLoadingAndKeepsLiveControlsUsable() {
        show()
        rule.onNodeWithText("Scroll up").performClick()
        rule.runOnIdle {
            val request = sent.last { it.kind == "scroll" }.payload()
            receive(control("failure", obj(
                "requestID" to request.string("requestID"),
                "subscriptionID" to lease,
                "error" to "SCROLL_UNAVAILABLE: The pane is not available for scrolling.",
            )))
        }
        rule.onNodeWithText("Loading…").assertDoesNotExist()
        rule.onNodeWithText("SCROLL_UNAVAILABLE: The pane is not available for scrolling.").assertIsDisplayed()
        rule.onNodeWithText("Scroll down").assertIsEnabled()
        rule.runOnIdle { assertEquals(Status.live, session.state.value.status) }
        screenshot("unavailable")
    }
}
