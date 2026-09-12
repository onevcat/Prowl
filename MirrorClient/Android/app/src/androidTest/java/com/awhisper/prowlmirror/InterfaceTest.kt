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
    fun contentExtendsBehindTransparentSystemBars() {
        rule.onNodeWithText("Add Remote Pane").assertIsDisplayed()
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
        rule.onNodeWithText("Add Remote Pane").performClick()
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
        rule.onNodeWithText("Add Remote Pane").performClick()
        rule.onNodeWithTag("code-first").performClick()
        for (character in "ABCD") {
            rule.onNode(isFocused()).performTextInput(character.toString())
        }
        rule.onNodeWithTag("code-second").performClick()
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
    fun addHostPairingHalvesRemainEditable() {
        rule.onNodeWithText("Add Remote Pane").performClick()
        rule.onNodeWithTag("host-address").performTextInput("127.0.0.1")
        rule.onNodeWithTag("code-first").performTextInput("ABCD2345")
        rule.onNodeWithTag("code-first").assertTextContains("ABCD")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithTag("code-first").performTextReplacement("EFGH")
        rule.onNodeWithTag("code-first").assertTextContains("EFGH")
        rule.onNodeWithTag("code-second").assertTextContains("2345")
        rule.onNodeWithText("Cancel").performClick()
        rule.onNodeWithText("Connect to Prowl").assertIsDisplayed()
    }
}
