package com.onevcat.prowl.mirror

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LaunchTest {
    @Test
    fun listsUnopenedWorktreesAndRestoresTheLastAvailableProfile() = runTest {
        val unopened = obj("id" to "unopened", "root_path" to "/project")
        val visible = obj("id" to "existing", "root_path" to "/other")
        fun profile(id: String, available: Boolean) =
            obj("id" to id, "enabled" to true, "availability" to obj("status" to if (available) "available" else "missing"))
        val model = LaunchModel(
            backgroundScope,
            { request ->
                if (request.has("list")) obj("ok" to true, "data" to obj(
                    "worktrees" to listOf(unopened, visible), "items" to listOf(obj("worktree" to visible)),
                )) else obj("ok" to true, "data" to obj(
                    "profiles" to listOf(profile("first", true), profile("last", true), profile("missing", false)),
                ))
            },
            loadProfile = { "last" },
        ) { _, _ -> fail("Should not create") }
        model.open()
        runCurrent()
        assertEquals(listOf(unopened, visible), model.state.value.worktrees)
        assertEquals("unopened", model.state.value.worktree)
        assertEquals("last", model.state.value.profile)
        assertEquals(3, model.state.value.profiles.size)
        model.selectProfile("missing")
        assertEquals("last", model.state.value.profile)
        assertTrue(model.state.value.canCreate)
        model.open(setOf("UNLISTED-PANE"))
        runCurrent()
        assertEquals("", model.state.value.worktree)
        assertFalse(model.state.value.canCreate)
    }

    @Test
    fun createUncertaintySurvivesReopeningAndCannotReplay() = runTest {
        val pending = CompletableDeferred<com.google.gson.JsonObject>()
        var creates = 0
        val model =
            LaunchModel(
                backgroundScope,
                { command ->
                    when {
                        command.has("list") ->
                            obj(
                                "ok" to true,
                                "data" to
                                    obj(
                                        "items" to
                                            listOf(
                                                obj(
                                                    "worktree" to
                                                        obj(
                                                            "id" to "w",
                                                            "name" to "main",
                                                            "path" to "/tmp",
                                                            "root_path" to "/tmp",
                                                        )
                                                )
                                            )
                                    ),
                            )
                        command.has("profiles") ->
                            obj(
                                "ok" to true,
                                "data" to
                                    obj(
                                        "profiles" to
                                            listOf(
                                                obj(
                                                    "id" to "p",
                                                    "name" to "Codex",
                                                    "enabled" to true,
                                                    "availability" to obj("status" to "available"),
                                                )
                                            )
                                    ),
                            )
                        else -> {
                            creates++
                            pending.await()
                        }
                    }
                },
                choose = { _, _ -> fail("Should not create") },
            )
        model.open()
        runCurrent()
        assertTrue(model.state.value.canCreate)
        model.create()
        runCurrent()
        model.open()
        assertTrue(model.state.value.creating)
        pending.completeExceptionally(java.io.IOException("lost"))
        runCurrent()
        assertTrue(model.state.value.uncertain)
        model.open()
        runCurrent()
        model.create()
        runCurrent()
        assertEquals(1, creates)
        assertFalse(model.state.value.canCreate)
    }
}
