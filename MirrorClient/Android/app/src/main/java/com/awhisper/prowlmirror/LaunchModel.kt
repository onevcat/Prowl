package com.awhisper.prowlmirror

import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class LaunchState(
    val worktrees: List<JsonObject> = emptyList(),
    val profiles: List<JsonObject> = emptyList(),
    val worktree: String = "",
    val profile: String = "",
    val prompt: String = "",
    val loading: Boolean = false,
    val creating: Boolean = false,
    val uncertain: Boolean = false,
    val error: String? = null,
    val created: String? = null,
) {
    val canCreate
        get() =
            !loading &&
                !creating &&
                !uncertain &&
                worktrees.any { it.string("id") == worktree } &&
                profiles.any { it.string("id") == profile } &&
                prompt.toByteArray().size <= Wire.MAX_INPUT
}

/** Session-owned so UI recreation never resets an in-flight or uncertain creation. */
class LaunchModel(
    private val scope: CoroutineScope,
    private val execute: suspend (JsonObject) -> JsonObject,
    private val choose: (Pane, Boolean) -> Unit,
) {
    val state = MutableStateFlow(LaunchState())

    fun selectWorktree(id: String) {
        state.update { it.copy(worktree = id) }
    }

    fun selectProfile(id: String) {
        state.update { it.copy(profile = id) }
    }

    fun setPrompt(text: String) {
        state.update { it.copy(prompt = text) }
    }

    fun acknowledgeUnknown() {
        state.update { it.copy(uncertain = false, error = null) }
    }

    fun open() {
        if (state.value.creating || state.value.loading) return
        state.update { it.copy(loading = true, created = null) }
        scope.launch {
            try {
                val listing = execute(Commands.list())
                require(listing.flag("ok")) { "Could not list workspaces" }
                val worktrees =
                    listing
                        .record("data")
                        .array("items")
                        .map { it.asJsonObject.record("worktree") }
                        .distinctBy { it.string("id") }
                val catalog = execute(Commands.profiles())
                require(catalog.flag("ok")) { "Could not load profiles" }
                val profiles =
                    catalog
                        .record("data")
                        .array("profiles")
                        .map { it.asJsonObject }
                        .filter {
                            it.flag("enabled") &&
                                it.record("availability").string("status") == "available"
                        }
                state.update {
                    it.copy(
                        worktrees = worktrees,
                        profiles = profiles,
                        worktree =
                            it.worktree.takeIf { id -> worktrees.any { w -> w.string("id") == id } }
                                ?: worktrees.firstOrNull()?.string("id").orEmpty(),
                        profile =
                            it.profile.takeIf { id -> profiles.any { p -> p.string("id") == id } }
                                ?: profiles.firstOrNull()?.string("id").orEmpty(),
                    )
                }
            } catch (e: Exception) {
                state.update { it.copy(error = e.message) }
            } finally {
                state.update { it.copy(loading = false) }
            }
        }
    }

    fun create() {
        val snapshot = state.value
        if (!snapshot.canCreate) return
        state.update { it.copy(creating = true, error = null) }
        scope.launch {
            try {
                val response =
                    execute(Commands.create(snapshot.worktree, snapshot.profile, snapshot.prompt))
                if (!response.flag("ok")) {
                    val failure = response.record("error")
                    state.update {
                        it.copy(
                            uncertain =
                                failure.optionalString("code") == "REMOTE_COMMAND_UNCONFIRMED",
                            error = failure.string("message"),
                        )
                    }
                } else {
                    val target = response.record("data").record("target")
                    val pane = target.record("pane")
                    val tree = target.record("worktree")
                    val descriptor =
                        Pane(
                            canonical(pane.string("id")),
                            pane.string("title"),
                            tree.string("path"),
                            false,
                            tree.string("root_path").substringAfterLast('/'),
                            tree.string("name"),
                        )
                    choose(descriptor, true)
                    state.update { it.copy(created = descriptor.id) }
                }
            } catch (e: Exception) {
                state.update {
                    it.copy(
                        uncertain = true,
                        error = "Creation unconfirmed. Review Host panes before creating another.",
                    )
                }
            } finally {
                state.update { it.copy(creating = false) }
            }
        }
    }
}
