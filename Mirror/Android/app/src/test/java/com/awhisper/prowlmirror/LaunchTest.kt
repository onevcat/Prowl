package com.awhisper.prowlmirror

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LaunchTest {
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
                { _, _ -> fail("Should not create") },
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
