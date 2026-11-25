package com.awhisper.prowlmirror

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class InterfaceTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun demoOpensAConversationAndExitsWithoutPairing() {
        rule.onNodeWithText("Try the Demo").performScrollTo().performClick()
        rule.onNodeWithText("Demo Mac").assertIsDisplayed()
        rule.onNodeWithTag("agents-roster").performScrollToNode(hasText("Draft 8.4 release notes"))
        rule.onNodeWithText("Draft 8.4 release notes").performClick()
        rule.onNodeWithTag("composer").performTextInput("Can we ship?")
        rule.onNodeWithContentDescription("Send").performClick()
        val reply = "This is the demo, so no agent runs here and nothing changes on a Mac."
        rule.waitUntil(8_000) {
            rule.onAllNodesWithText(reply, substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText(reply, substring = true).assertIsDisplayed()
        rule.onNodeWithContentDescription("Agents").performClick()
        rule.onNodeWithContentDescription("Settings").performClick()
        rule.onNodeWithText("Exit Demo").performClick()
        rule.onNodeWithText("Pair with a Mac").assertIsDisplayed()
    }

    @Test
    fun workingDemoQueuesInputAndStopStartsIt() {
        rule.onNodeWithText("Try the Demo").performScrollTo().performClick()
        rule.onNodeWithTag("agents-roster").performScrollToNode(hasText("Scan unused images"))
        rule.onNodeWithText("Scan unused images").performClick()
        rule.onNodeWithTag("composer").performTextInput("Check the queued follow-up")
        rule.onNodeWithContentDescription("Send").performClick()
        rule.onNodeWithText("queued").assertIsDisplayed()
        rule.onNodeWithContentDescription("Stop").performClick()
        rule.onNodeWithText("Stop this agent?").assertIsDisplayed()
        rule.onNodeWithText("Stop").performClick()
        rule.onNodeWithText("Interrupted. Tell Codex what to do differently.").assertExists()
        rule.onNodeWithText("queued").assertDoesNotExist()
        rule.onNodeWithText("Check the queued follow-up").assertIsDisplayed()
    }

    @Test
    fun demoApprovalAndTerminalUseTheNormalPaneControls() {
        rule.onNodeWithText("Try the Demo").performScrollTo().performClick()
        rule.onNodeWithTag("agents-roster").performScrollToNode(hasText("Fix flaky prefetch test"))
        rule.onNodeWithText("Fix flaky prefetch test").performClick()
        rule.onNodeWithText("Do you want to proceed?").assertIsDisplayed()
        rule.onNodeWithTag("prompt-choice-1").performClick()
        rule.onNodeWithText("Allowed · Do you want to proceed?").assertIsDisplayed()
        rule.onNodeWithContentDescription("Terminal").performClick()
        rule.onNodeWithContentDescription("Scroll Up").assertIsEnabled()
        rule.onNodeWithContentDescription("Scroll Down").assertIsNotEnabled()
        rule.onNodeWithContentDescription("Scroll Up").performClick()
        rule.onNodeWithContentDescription("Scroll Down").assertIsEnabled()
        rule.onNodeWithContentDescription("Chat").performClick()
        rule.onNodeWithText("Allowed · Do you want to proceed?").assertIsDisplayed()
        rule.onNodeWithContentDescription("Agents").performClick()
        rule.onNodeWithContentDescription("Settings").performClick()
        rule.onNodeWithText("Settings…").performClick()
        rule.onNodeWithText("Prowl Website").assertIsDisplayed()
        rule.onNodeWithText("Paired Hosts").assertDoesNotExist()
    }

    @Test
    fun demoShellEchoesInputAndKeepsASnapshot() {
        rule.onNodeWithText("Try the Demo").performScrollTo().performClick()
        val roster = rule.onNodeWithTag("agents-roster")
        roster.performScrollToNode(hasTestTag("terminals-Prowl"))
        rule.onNodeWithTag("terminals-Prowl").performClick()
        roster.performScrollToNode(hasText("zsh"))
        rule.onNodeWithText("zsh").performClick()
        rule.onNodeWithTag("composer").performTextInput("pwd")
        rule.onNodeWithContentDescription("Send").performClick()
        rule.onNodeWithText("demo: Commands do not run in the demo.", substring = true).assertIsDisplayed()
        rule.onNodeWithContentDescription("Pane actions").performClick()
        rule.onNodeWithText("History").performClick()
        rule.onNodeWithText("Loaded lines 1–", substring = true).assertIsDisplayed()
    }

    @Test
    fun newSessionNamesTheSelectedProjectAndBranch() {
        rule.onNodeWithText("Try the Demo").performScrollTo().performClick()
        rule.onNodeWithContentDescription("New Session").performClick()
        rule.onNodeWithText("Prowl · main").assertIsDisplayed().performClick()
        rule.onNodeWithText("/Users/demo/Projects/Kingfisher-8.4").performClick()
        rule.onNodeWithText("Kingfisher · release/8.4").assertIsDisplayed()
    }

    @Test
    fun onboardingArrangesTheBrandAndActionsForTheWindowShape() {
        val window = rule.onRoot().fetchSemanticsNode().boundsInRoot
        val brand = rule.onNodeWithTag("onboarding-brand").fetchSemanticsNode().boundsInRoot
        val setup = rule.onNodeWithTag("onboarding-setup").fetchSemanticsNode().boundsInRoot
        if (window.width > window.height)
            org.junit.Assert.assertTrue(brand.right <= setup.left)
        else org.junit.Assert.assertTrue(brand.bottom <= setup.top)
        rule.onNodeWithText("Pair with a Mac").assertIsDisplayed()
        rule.onNodeWithText("Try the Demo").assertIsDisplayed()
    }

    @Test
    fun contentExtendsBehindTransparentSystemBars() {
        rule.onNodeWithText("Pair with a Mac").assertIsDisplayed()
        rule.runOnIdle {
            val window = rule.activity.window
            org.junit.Assert.assertEquals(android.graphics.Color.TRANSPARENT, window.statusBarColor)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                org.junit.Assert.assertFalse(window.isNavigationBarContrastEnforced)
            }
            val content = rule.activity.findViewById<android.view.View>(android.R.id.content)
            val location = IntArray(2)
            content.getLocationInWindow(location)
            org.junit.Assert.assertEquals(0, location[1])
            org.junit.Assert.assertEquals(window.decorView.height, content.height)
        }
    }

    @Test
    fun overflowKeysDoNotOverwriteSecondHalf() {
        rule.onNodeWithText("Pair with a Mac").performClick()
        rule.onNodeWithTag("code-first").performTextInput("ABCD")
        rule.onNodeWithTag("code-second").performTextInput("6789")
        for (chunk in listOf("23", "45")) {
            rule.onNodeWithTag("code-first").performTextInput(chunk)
        }
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("6789")
    }

    @Test
    fun typingPairingCodeCharacterByCharacterPreservesFocusAndBothHalves() {
        rule.onNodeWithText("Pair with a Mac").performClick()
        rule.onNodeWithTag("code-first").performClick()
        for (character in "ABCD") {
            rule.onNode(isFocused()).performTextInput(character.toString())
        }
        rule.onNodeWithTag("code-second").assertIsFocused()
        for (character in "2345") {
            rule.onNode(isFocused()).performTextInput(character.toString())
        }
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithTag("code-second").assertIsFocused()
        rule.onNodeWithTag("code-first").performTextReplacement("EFGH")
        rule.onNodeWithTag("code-first").assertTextContains("EFGH").assertIsFocused()
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithTag("code-first").performTextClearance()
        rule.onNodeWithTag("code-first").performTextInput("JKLM")
        rule.onNodeWithTag("code-first").assertTextContains("JKLM").assertIsFocused()
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithTag("code-second").performTextReplacement("6789")
        rule.onNodeWithTag("code-second").assertTextContains("6789")
        rule.onNodeWithTag("code-first").assertTextContains("JKLM")
    }

    @Test
    fun pastingTheCompleteCodeInTheSecondFieldFillsBothHalves() {
        rule.onNodeWithText("Pair with a Mac").performClick()
        rule.onNodeWithTag("code-second").performTextInput("ABCD-2345")
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
    }

    @Test
    fun pairingFieldsSurviveActivityRecreation() {
        rule.onNodeWithText("Pair with a Mac").performClick()
        rule.onNodeWithTag("host-address").performTextInput("192.168.1.12")
        rule.onNodeWithTag("code-first").performTextInput("ABCD2345")
        rule.activityRule.scenario.recreate()
        rule.onNodeWithTag("host-address").assertTextContains("192.168.1.12")
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
    }

    @Test
    fun addHostPairingHalvesRemainEditable() {
        rule.onNodeWithText("Pair with a Mac").performClick()
        rule.onNodeWithTag("host-address").performTextInput("127.0.0.1")
        rule.onNodeWithTag("code-first").performTextInput("ABCD2345")
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithTag("code-first").performTextReplacement("EFGH")
        rule.onNodeWithTag("code-first").assertTextContains("EFGH")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithText("Cancel").performClick()
        rule.onNodeWithText("Prowl Mirror").assertIsDisplayed()
    }
}
