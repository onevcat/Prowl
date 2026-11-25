package com.onevcat.prowl.mirror

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
                profiles.any { it.string("id") == profile && it.canLaunchProfile() } &&
                prompt.toByteArray().size <= Wire.MAX_INPUT
}

/** Session-owned so UI recreation never resets an in-flight or uncertain creation. */
class LaunchModel(
    private val scope: CoroutineScope,
    private val execute: suspend (JsonObject) -> JsonObject,
    private val loadProfile: () -> String? = { null },
    private val saveProfile: (String) -> Unit = {},
    private val choose: (Pane, String?) -> Unit,
) {
    val state = MutableStateFlow(LaunchState())

    fun selectWorktree(id: String) {
        state.update { it.copy(worktree = id) }
    }

    fun selectProfile(id: String) {
        if (state.value.profiles.none { it.string("id") == id && it.canLaunchProfile() }) return
        state.update { it.copy(profile = id) }
    }

    fun setPrompt(text: String) {
        state.update { it.copy(prompt = text) }
    }

    fun acknowledgeUnknown() {
        state.update { it.copy(uncertain = false, error = null) }
    }

    fun open(projectPanes: Set<String>? = null) {
        if (state.value.creating || state.value.loading || state.value.uncertain) return
        state.update { it.copy(loading = true, created = null, error = null) }
        scope.launch {
            try {
                val listing = execute(Commands.list())
                require(listing.flag("ok")) { "Could not list workspaces" }
                val data = listing.record("data")
                val items = data.array("items").map { it.asJsonObject }
                val worktrees = (data.get("worktrees")?.takeUnless { it.isJsonNull }?.asJsonArray?.map { it.asJsonObject }
                    ?: items.map { it.record("worktree") }).distinctBy { it.string("id") }
                val projectDefault = projectPanes?.let { ids ->
                    val treeIDs = items.filter { item ->
                        item.get("pane")?.takeUnless { it.isJsonNull }?.asJsonObject?.optionalString("id")?.uppercase() in ids
                    }.mapTo(mutableSetOf()) { it.record("worktree").string("id") }
                    val matches = worktrees.filter { it.string("id") in treeIDs }
                    matches.firstOrNull { it.string("path").trimEnd('/') == it.string("root_path").trimEnd('/') }
                        ?: matches.firstOrNull()
                }
                val catalog = execute(Commands.profiles())
                require(catalog.flag("ok")) { "Could not load profiles" }
                val profiles =
                    catalog
                        .record("data")
                        .array("profiles")
                        .map { it.asJsonObject }
                val availableProfiles = profiles.filter { it.canLaunchProfile() }.map { it.string("id") }
                state.update {
                    it.copy(
                        worktrees = worktrees,
                        profiles = profiles,
                        worktree = if (projectPanes != null) projectDefault?.string("id").orEmpty()
                        else it.worktree.takeIf { id -> worktrees.any { w -> w.string("id") == id } }
                            ?: worktrees.firstOrNull()?.string("id").orEmpty(),
                        profile =
                            loadProfile()?.takeIf { id -> id in availableProfiles }
                                ?: it.profile.takeIf { id -> id in availableProfiles }
                                ?: availableProfiles.firstOrNull().orEmpty(),
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
                            agent = pane.optionalString("agent") ?: snapshot.profiles
                                .firstOrNull { it.string("id") == snapshot.profile }?.optionalString("runtime"),
                            worktreeName = tree.string("name"),
                        )
                    saveProfile(snapshot.profile)
                    val kickoff = snapshot.prompt.takeIf { it.isNotBlank() && descriptor.agent in setOf("codex", "claude") }
                    choose(descriptor, kickoff)
                    state.update { it.copy(created = descriptor.id, prompt = "") }
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

internal fun JsonObject.canLaunchProfile() =
    flag("enabled") && record("availability").string("status") == "available"
