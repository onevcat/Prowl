package com.awhisper.prowlmirror

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentsRosterTest {
    @Test
    fun ranksAgentsByUrgencyWithinMacProjectOrder() {
        val shell = Pane(uuid(), "Shell", "/b", false, "B", projectOrder = 1)
        val working = shell.copy(id = uuid(), title = "Working", agent = "codex", displayState = "working")
        val blocked = working.copy(id = uuid(), title = "Blocked", displayState = "blocked")
        val other = working.copy(id = uuid(), projectName = "A", projectOrder = 2)
        val panes = listOf(other, shell, working, blocked)

        val groups = rosterProjects(panes, null)
        assertEquals(listOf("B", "A"), groups.map { it.first })
        assertEquals(listOf(blocked, working, shell), groups.first().second)
        assertEquals(listOf("B" to listOf(blocked)), rosterProjects(panes, "blocked"))
    }
}
