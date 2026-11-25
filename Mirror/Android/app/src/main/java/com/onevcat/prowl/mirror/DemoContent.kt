package com.onevcat.prowl.mirror

import com.google.gson.JsonObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Events that arrive [delay] milliseconds after the previous step, in one batch. */
internal class DemoStep(val delay: Long, val events: List<JsonObject>)

internal data class DemoWorktree(val name: String, val path: String, val rootPath: String) {
    val id get() = path
    val json get() = obj("id" to id, "name" to name, "path" to path, "root_path" to rootPath)
    val shellPrompt get() = "${rootPath.substringAfterLast('/')} $name ❯ "
}

internal data class DemoProfile(val id: String, val name: String, val runtime: String) {
    val json get() = obj("id" to id, "name" to name, "enabled" to true, "runtime" to runtime,
        "availability" to obj("status" to "available"))
}

private val timestamps = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

internal fun demoTimestamp(at: Instant): String = timestamps.format(at)

/** A demo event; the pane numbers it, and dates it when [at] is null. */
internal fun demoEvent(kind: String, data: JsonObject, source: String = "transcript", at: Instant? = null) =
    obj("kind" to kind, "source" to source, "data" to data, "ts" to at?.let(::demoTimestamp))

private fun text(value: String) = obj("text" to value)

/** One pane of the demo Mac (docs-ai 098): its descriptor, sequenced events, open screen prompt and scripts. */
internal class DemoPane(
    id: String, tab: String, project: String, color: String, order: Int,
    val worktree: DemoWorktree, val agent: String?,
) {
    val descriptor: JsonObject = obj(
        "id" to id, "title" to "$project · $tab · ${worktree.name}", "directory" to worktree.path, "busy" to false,
        "projectName" to project, "subtitle" to "$tab · ${worktree.name}", "agent" to agent,
        "agentState" to agent?.let { "idle" }, "displayState" to agent?.let { "idle" },
        "conversation" to if (agent == null) "unsupported" else "available",
        "tabTitle" to tab, "worktreeName" to worktree.name, "repositoryColor" to color, "projectOrder" to order,
    )
    val events = mutableListOf<JsonObject>()
    /** The menu on the screen that a phone can answer, while it is open. */
    var prompt: JsonObject? = null
        private set
    /** The scripts that follow an answer, by choice id; `*` for any other choice. */
    var answers: Map<String, List<DemoStep>> = emptyMap()
    /** Work that plays from the start of the demo without input. */
    var autoplay: List<DemoStep> = emptyList()
    val shell = mutableListOf<String>()

    val id get() = descriptor.string("id")
    val agentState get() = descriptor.optionalString("agentState")
    val agentName
        get() = when (agent) {
            "claude" -> "Claude Code"
            "codex" -> "Codex"
            null -> "Shell"
            else -> agent.replaceFirstChar(Char::uppercase)
        }

    fun agentStartEvents(): List<JsonObject> = if (agent == null) emptyList() else listOf(
        demoEvent("session.started", obj("id" to uuid().lowercase(), "cwd" to worktree.path)),
        demoEvent("agent.status", obj("state" to "idle"), source = "osc"),
    )

    /** Numbers and dates events in order, and follows the state and the open prompt they report. */
    fun append(newEvents: List<JsonObject>, at: Instant = Instant.now()) {
        for (template in newEvents) {
            val event = template.deepCopy()
            event.addProperty("seq", events.size + 1)
            if (event.optionalString("ts") == null) event.addProperty("ts", demoTimestamp(at))
            events += event
            val data = event.record("data")
            when (event.string("kind")) {
                "agent.status" -> setState(data.string("state"), event.string("ts"))
                "prompt.opened" -> if (event.string("source") == "screen") prompt = data
                "prompt.resolved" -> if (data.optionalString("id") == prompt?.optionalString("id")) prompt = null
            }
        }
    }

    fun setDisplayState(state: String) = descriptor.addProperty("displayState", state)

    fun setStateChangedAt(at: Instant) = descriptor.addProperty("stateChangedAt", demoTimestamp(at))

    private fun setState(state: String, at: String) {
        val previous = descriptor.optionalString("displayState")
        descriptor.addProperty("agentState", state)
        // As on the Mac: a turn that just ended is done until someone looks at it.
        val display = when (state) {
            "working", "blocked" -> state
            else -> if (previous == "working" || previous == "blocked") "done" else "idle"
        }
        descriptor.addProperty("displayState", display)
        if (display != previous) descriptor.addProperty("stateChangedAt", at)
    }

    /** What Stop leaves: the running tools and the turn end as interrupted, and the agent waits. */
    fun interruptionEvents(): List<JsonObject> {
        val ended = events.filter { it.string("kind") == "tool.completed" }
            .mapTo(mutableSetOf()) { it.record("data").string("id") }
        val open = events.filter { it.string("kind") == "tool.started" }.map { it.record("data") }
            .filter { it.string("id") !in ended }
        return open.map {
            demoEvent("tool.completed", obj("id" to it.string("id"), "name" to it.string("name"), "status" to "interrupted"))
        } + listOf(
            demoEvent("turn.completed", obj("status" to "aborted", "reason" to "interrupted")),
            demoEvent("notice", obj("level" to "info", "text" to "Interrupted. Tell $agentName what to do differently.")),
            demoEvent("agent.status", obj("state" to "idle"), source = "osc"),
        )
    }

    /** A shell command from the phone: shown at the prompt, not run. */
    fun runShellCommand(command: String) {
        if (shell.lastOrNull() == worktree.shellPrompt) shell.removeAt(shell.lastIndex)
        shell += worktree.shellPrompt + command
        shell += "demo: Commands do not run in the demo. On a paired Mac they run in this pane."
        shell += worktree.shellPrompt
    }

    /** The terminal screen: the last lines of the session, or an earlier window [offset] lines up from the end. */
    fun screen(offset: Int = 0): String {
        val lines = transcriptLines()
        val end = lines.size - offset.coerceIn(0, maximumScroll(lines))
        return lines.subList((end - SCREEN_LINES).coerceAtLeast(0), end).joinToString("\n")
    }

    val maximumScroll get() = maximumScroll(transcriptLines())

    private fun maximumScroll(lines: List<String>) = (lines.size - SCREEN_LINES).coerceAtLeast(0)

    /** Everything the pane printed, for the terminal history. */
    val historyLines get() = transcriptLines()

    private fun transcriptLines(): List<String> {
        if (agent == null) return shell.toList()
        val codex = agent == "codex"
        val bullet = if (codex) "•" else "⏺"
        val lines = mutableListOf(if (codex) ">_ Codex · ${worktree.path}" else "✻ Claude Code · ${worktree.path}", "")
        val ends = events.filter { it.string("kind") == "tool.completed" }.map { it.record("data") }
            .associateBy { it.string("id") }
        fun add(first: String, text: String) {
            val parts = text.split("\n")
            lines += first + parts.first()
            lines += parts.drop(1).map { "  $it" }
            lines += ""
        }
        for (event in events) {
            val data = event.record("data")
            when (event.string("kind")) {
                "user.message", "user.unqueued" -> add("> ", data.record("text").string("text"))
                "assistant.message" -> add("$bullet ", data.record("text").string("text"))
                "tool.started" -> {
                    val target = data.optionalString("command") ?: data.optionalString("path") ?: data.string("title")
                    lines += "$bullet ${data.string("name")}($target)"
                    lines += "  ⎿  " + summary(ends[data.string("id")])
                    lines += ""
                }
                "notice" -> add("  ", data.string("text"))
            }
        }
        val open = prompt
        when {
            open != null -> {
                // As the agent draws it: the quoted lines, such as the command, above the question.
                open.getAsJsonObject("detail")?.optionalString("text")?.let { detail ->
                    lines += detail.split("\n").filter { it.isNotEmpty() }.map { "  $it" }
                }
                open.optionalString("title")?.let { lines += it }
                open.getAsJsonArray("choices")?.forEachIndexed { index, element ->
                    val choice = element.asJsonObject
                    lines += (if (index == 0) "❯ " else "  ") + "${choice.string("id")}. ${choice.string("label")}"
                }
            }
            agentState == "working" -> lines += if (codex) "• Working (esc to interrupt)" else "✻ Working… (esc to interrupt)"
            else -> lines += ">"
        }
        return lines
    }

    private fun summary(end: JsonObject?): String {
        end ?: return "Running…"
        val output = end.getAsJsonObject("output")?.optionalString("text")?.split("\n")?.filter { it.isNotEmpty() }.orEmpty()
        return when (end.string("status")) {
            "interrupted" -> "Interrupted"
            "error" -> output.firstOrNull() ?: "Failed"
            else -> if (end.has("diff")) "Updated" else output.lastOrNull() ?: "Done"
        }
    }

    companion object {
        const val SCREEN_LINES = 48

        /** A pane New Session created next to [template], in the same worktree. */
        fun launched(template: DemoPane, profile: DemoProfile?) = DemoPane(
            uuid(), profile?.name ?: "zsh", template.descriptor.string("projectName"),
            template.descriptor.string("repositoryColor"), template.descriptor.integer("projectOrder"),
            template.worktree, profile?.runtime,
        ).apply {
            if (profile == null) shell += worktree.shellPrompt
            setStateChangedAt(Instant.now())
        }
    }
}

/**
 * What the demo Mac holds (docs-ai 098), ported from the iOS `MirrorDemoContent`: four agents in every state and
 * two shells, in three projects. The text is the agents' output, so it stays English like real agent output.
 */
internal object DemoContent {
    const val HOST_NAME = "Demo Mac"
    /** The permission menu of the blocked pane. */
    const val BLOCKED_PROMPT_ID = "screen:5f1d2c.1"
    const val WORKING_RUNS_FOR = 120_000L

    /** Stable pane IDs, shared with the iOS demo. */
    object PaneID {
        const val BLOCKED = "D0000000-0000-0000-0000-000000000001"
        const val WORKING = "D0000000-0000-0000-0000-000000000002"
        const val DONE = "D0000000-0000-0000-0000-000000000003"
        const val IDLE = "D0000000-0000-0000-0000-000000000004"
        const val PROWL_SHELL = "D0000000-0000-0000-0000-000000000005"
        const val KINGFISHER_SHELL = "D0000000-0000-0000-0000-000000000006"
    }

    val profiles = listOf(
        DemoProfile("claude", "Claude Code", "claude"),
        DemoProfile("codex", "Codex", "codex"),
    )

    private const val ROOT = "/Users/demo/Projects"
    private val prowl = DemoWorktree("main", "$ROOT/Prowl", "$ROOT/Prowl")
    private val kingfisher = DemoWorktree("main", "$ROOT/Kingfisher", "$ROOT/Kingfisher")
    private val kingfisherRelease = DemoWorktree("release/8.4", "$ROOT/Kingfisher-8.4", "$ROOT/Kingfisher")
    private val fengNiao = DemoWorktree("main", "$ROOT/FengNiao", "$ROOT/FengNiao")

    fun standard(now: Instant = Instant.now(), workingRunsFor: Long = WORKING_RUNS_FOR): List<DemoPane> {
        fun ago(minutes: Double): Instant = now.minusMillis((minutes * 60_000).toLong())
        return listOf(blockedPane(::ago), workingPane(::ago, workingRunsFor), donePane(::ago), idlePane(::ago)) +
            shellPanes(::ago)
    }

    /** The answer to anything sent to an agent in the demo: what would happen on a Mac. */
    fun reply(message: String, agent: String): List<DemoStep> {
        val tool = "demo-${uuid().take(8).lowercase()}"
        return listOf(
            DemoStep(0, listOf(
                demoEvent("turn.started", obj("origin" to "human")),
                demoEvent("user.message", obj("text" to text(message), "origin" to "human")),
                demoEvent("agent.status", obj("state" to "working"), source = "osc"),
            )),
            DemoStep(1_200, listOf(demoEvent("assistant.reasoning", obj("durationMs" to 1100)))),
            DemoStep(800, listOf(demoEvent("tool.started", obj("id" to tool, "name" to "Read", "kind" to "read",
                "title" to "Read the request", "path" to "Demo.md")))),
            DemoStep(1_400, listOf(
                demoEvent("tool.completed", obj("id" to tool, "name" to "Read", "status" to "succeeded",
                    "output" to text("Read 12 lines"), "durationMs" to 1400)),
                final("""
                    This is the demo, so no agent runs here and nothing changes on a Mac.

                    With Prowl on your Mac, $agent gets this message in its pane, and you follow the work here: its messages, the tools it runs, and the questions it asks you.

                    To use your own agents, exit the demo and pair with a Mac that runs Prowl.
                """.trimIndent()),
                demoEvent("turn.completed", obj("origin" to "human", "status" to "completed", "durationMs" to 3400)),
                demoEvent("agent.status", obj("state" to "idle"), source = "osc"),
            )),
        )
    }

    private fun final(value: String, at: Instant? = null) =
        demoEvent("assistant.message", obj("text" to text(value), "phase" to "final"), at = at)

    private fun commentary(value: String, at: Instant) =
        demoEvent("assistant.message", obj("text" to text(value), "phase" to "commentary"), at = at)

    private fun reasoning(durationMs: Int, at: Instant? = null) =
        demoEvent("assistant.reasoning", obj("durationMs" to durationMs), at = at)

    private fun status(state: String, at: Instant? = null, kind: String? = null) =
        demoEvent("agent.status", obj("state" to state, "kind" to kind), source = "osc", at = at)

    /** The opening of a human turn: the session, the message, and the agent starting to work. */
    private fun opening(session: JsonObject, message: String, at: Instant) = listOf(
        demoEvent("session.started", session, at = at),
        demoEvent("turn.started", obj("origin" to "human"), at = at),
        demoEvent("user.message", obj("text" to text(message), "origin" to "human"), at = at),
        status("working", at),
    )

    private fun completed(durationMs: Int, at: Instant? = null) =
        demoEvent("turn.completed", obj("origin" to "human", "status" to "completed", "durationMs" to durationMs), at = at)

    /** A finished tool call: its start and its end. */
    private fun tool(start: JsonObject, output: String, at: Instant): List<JsonObject> = listOf(
        demoEvent("tool.started", start, at = at),
        demoEvent("tool.completed", obj("id" to start.string("id"), "name" to start.string("name"),
            "status" to "succeeded", "exitCode" to 0.takeIf { start.string("kind") == "shell" },
            "output" to text(output), "durationMs" to 900), at = at.plusSeconds(1)),
    )

    private fun editTool(id: String, path: String, diff: String, at: Instant): List<JsonObject> = listOf(
        demoEvent("tool.started", obj("id" to id, "name" to "Edit", "kind" to "edit",
            "title" to "Edit ${path.substringAfterLast('/')}", "path" to path, "changedPaths" to listOf(path)), at = at),
        demoEvent("tool.completed", obj("id" to id, "name" to "Edit", "status" to "succeeded",
            "diff" to text(diff), "durationMs" to 300), at = at.plusSeconds(1)),
    )

    private fun start(id: String, name: String, kind: String, title: String, command: String? = null, path: String? = null) =
        obj("id" to id, "name" to name, "kind" to kind, "title" to title, "command" to command, "path" to path)

    /** Blocked: Claude Code asks to run the tests. */
    private fun blockedPane(ago: (Double) -> Instant) = DemoPane(
        PaneID.BLOCKED, "Fix flaky prefetch test", "Kingfisher", "blue", 1, kingfisher, "claude",
    ).apply {
        val testCommand = "scripts/repeat-tests.sh 50 ImagePrefetcherTests"
        append(
            opening(obj("id" to "7c1e0f52-demo", "cwd" to kingfisher.path, "model" to "claude-opus-5-5"),
                "ImagePrefetcherTests.testPrefetchCompletesAllSources fails about once in ten CI runs. " +
                    "Find out why and fix it.", ago(9.0)) +
                reasoning(4200, ago(8.9)) +
                commentary("I'll read the test first, then the prefetcher's completion path.", ago(8.8)) +
                tool(start("k1", "Read", "read", "Read the test", path = "Tests/KingfisherTests/ImagePrefetcherTests.swift"),
                    "Read 212 lines", ago(8.7)) +
                tool(start("k2", "Grep", "search", "pendingSources in Sources/"), "Found 6 matches in 2 files", ago(8.5)) +
                tool(start("k3", "Read", "read", "Read the prefetcher", path = "Sources/Networking/ImagePrefetcher.swift"),
                    "Read 431 lines", ago(8.3)),
            ago(9.0),
        )
        append(
            listOf(
                reasoning(6100, ago(7.9)),
                commentary("""
                    Found it. `handleComplete(for:)` removes the finished source under `lock`, but it reads `pendingSources.isEmpty` after the lock is released. When the last two sources finish at the same time, both can see a set that is not empty yet, so the completion handler never runs and the test times out.

                    I'll make the check part of the same critical section.
                """.trimIndent(), ago(7.8)),
            ) + editTool("k4", "Sources/Networking/ImagePrefetcher.swift", """
                @@ -214,9 +214,10 @@ extension ImagePrefetcher {
                     func handleComplete(for source: Source) {
                -        lock.lock()
                -        pendingSources.remove(source)
                -        lock.unlock()
                -        if pendingSources.isEmpty { reportCompletion() }
                +        let finished: Bool = lock.withLock {
                +            pendingSources.remove(source)
                +            return pendingSources.isEmpty
                +        }
                +        if finished { reportCompletion() }
                     }
            """.trimIndent(), ago(7.2)) + listOf(
                commentary("Now I'll run the prefetcher tests 50 times to make sure the failure is gone.", ago(2.2)),
                demoEvent("tool.started", start("k5", "Bash", "shell", "Run the tests 50 times", command = testCommand),
                    at = ago(2.1)),
                status("blocked", ago(2.0), kind = "permission"),
                demoEvent("prompt.opened", testRunPrompt(testCommand), source = "screen", at = ago(2.0)),
            ),
            ago(8.0),
        )
        answers = mapOf("1" to allowedTestRun(), "2" to allowedTestRun(), "*" to declinedTestRun())
    }

    /** Claude Code's permission menu for the test run, as the Host reads it from the screen. */
    private fun testRunPrompt(command: String) = obj(
        "id" to BLOCKED_PROMPT_ID, "kind" to "permission", "title" to "Do you want to proceed?",
        "detail" to text("Bash command\n$command\nRun the prefetcher tests 50 times"),
        "choices" to listOf(
            obj("id" to "1", "label" to "Yes"),
            obj("id" to "2", "label" to "Yes, and don't ask again for scripts/repeat-tests.sh commands in ${kingfisher.path}"),
            obj("id" to "3", "label" to "No, and tell Claude what to do differently (esc)"),
        ),
        "freeform" to false,
    )

    /** What follows when the person declines the test run. */
    private fun declinedTestRun() = listOf(
        DemoStep(0, listOf(demoEvent("tool.completed", obj("id" to "k5", "name" to "Bash", "status" to "error",
            "output" to text("The user declined this command."))))),
        DemoStep(1_000, listOf(
            final("Okay, I won't run the tests. The fix is in `Sources/Networking/ImagePrefetcher.swift`. " +
                "How do you want to check it?"),
            demoEvent("turn.completed", obj("origin" to "human", "status" to "completed")),
            status("idle"),
        )),
    )

    /** What follows when the person allows the test run. */
    private fun allowedTestRun() = listOf(
        DemoStep(0, listOf(status("working"))),
        DemoStep(3_000, listOf(demoEvent("tool.completed", obj("id" to "k5", "name" to "Bash", "status" to "succeeded",
            "exitCode" to 0, "output" to text("""
                Test Suite 'ImagePrefetcherTests' passed.
                ${"\t"} Executed 7 tests, with 0 failures (0 unexpected) in 0.841 seconds
                50 runs, 350 tests, 0 failures
            """.trimIndent()), "durationMs" to 41_800)))),
        DemoStep(1_200, listOf(reasoning(1800))),
        DemoStep(1_500, listOf(
            final("""
                The flaky failure is fixed.

                - **Cause:** `handleComplete(for:)` checked `pendingSources.isEmpty` outside the lock, so two sources that finished together could both miss the last completion.
                - **Fix:** the removal and the check now run in one `lock.withLock` block in `Sources/Networking/ImagePrefetcher.swift`.
                - **Check:** 50 runs of `ImagePrefetcherTests`, 350 tests, no failures. Before the change it failed 6 times in 50 runs.
            """.trimIndent()),
            completed(512_000),
            status("idle"),
        )),
    )

    /** Working: Codex scans for unused images until [runsFor] passes. */
    private fun workingPane(ago: (Double) -> Instant, runsFor: Long) = DemoPane(
        PaneID.WORKING, "Scan unused images", "FengNiao", "purple", 2, fengNiao, "codex",
    ).apply {
        append(
            opening(obj("id" to "019a-demo-fengniao", "cwd" to fengNiao.path),
                "Find image assets that no Swift, Objective-C, or storyboard file uses. " +
                    "List them with their sizes, largest first. Don't delete anything.", ago(4.0)) +
                reasoning(2600, ago(3.9)) +
                commentary("I'll count the assets first, then search the sources for each name, including names built " +
                    "at run time.", ago(3.8)) +
                tool(start("f1", "Shell", "shell", "Count image assets",
                    command = "fd -e png -e jpg -e pdf . Resources | wc -l"), "1284", ago(3.6)) +
                tool(start("f2", "Shell", "shell", "Find image names built at run time",
                    // No backslashes: the terminal screen reads Markdown, which would drop them.
                    command = "rg -n 'named: \"onboarding-' Sources"),
                    "Sources/Onboarding/PageView.swift:41:    UIImage(named: \"onboarding-\" + page.id)", ago(3.2)) +
                commentary("`onboarding-1` to `onboarding-4` are loaded by a built name, so I'll keep them. " +
                    "Now the full scan.", ago(3.0)) +
                demoEvent("tool.started", start("f3", "Shell", "shell", "Scan the sources for unused assets",
                    command = "fengniao --list-only --exclude Pods Carthage"), at = ago(2.9)),
            ago(4.0),
        )
        autoplay = listOf(
            DemoStep(runsFor, listOf(demoEvent("tool.completed", obj("id" to "f3", "name" to "Shell",
                "status" to "succeeded", "exitCode" to 0,
                "output" to text("Searching unused files... done\n6 unused files found (4.3 MB)"), "durationMs" to 301_000)))),
            DemoStep(1_500, listOf(
                final("""
                    I found 6 image assets that nothing uses, 4.3 MB in total. I did not delete anything.

                    | Asset | Size | Last changed |
                    | --- | --- | --- |
                    | `promo-banner-2025@3x.png` | 1.9 MB | 14 months ago |
                    | `legacy-splash.pdf` | 1.1 MB | 2 years ago |
                    | `tab-discover-old@2x.png` | 512 KB | 9 months ago |
                    | `badge-beta.imageset` | 384 KB | 11 months ago |
                    | `empty-state-search@3x.png` | 290 KB | 7 months ago |
                    | `icon-share-legacy.pdf` | 96 KB | 2 years ago |

                    `onboarding-1` to `onboarding-4` look unused, but `Sources/Onboarding/PageView.swift` loads them by a built name, so they are not in the list.

                    To remove these files, run `fengniao --exclude Pods Carthage` and confirm the list.
                """.trimIndent()),
                completed(420_000),
                status("idle"),
            )),
        )
    }

    /** Done: Codex drafted the release notes. */
    private fun donePane(ago: (Double) -> Instant) = DemoPane(
        PaneID.DONE, "Draft 8.4 release notes", "Kingfisher", "blue", 1, kingfisherRelease, "codex",
    ).apply {
        append(
            opening(obj("id" to "019a-demo-kingfisher", "cwd" to kingfisherRelease.path),
                "Draft the release notes for 8.4.0 from the pull requests merged since 8.3.2. Use the CHANGELOG format.",
                ago(14.0)) +
                reasoning(1900, ago(13.9)) +
                tool(start("r1", "Shell", "shell", "List merged pull requests",
                    command = "git log --merges --oneline 8.3.2..HEAD"), """
                    a41c9e2 Merge pull request #2398 from fix/prefetch-cancel
                    7b0d1f3 Merge pull request #2391 from feature/prefetch-progress
                    2c88e04 Merge pull request #2386 from fix/gif-frame-duration
                    9e13a5b Merge pull request #2380 from feature/visionos-memory-cache
                """.trimIndent(), ago(13.7)) +
                tool(start("r2", "Read", "read", "Read the changelog", path = "CHANGELOG.md"), "Read 80 lines", ago(13.2)) +
                listOf(
                    final("""
                        Here are the notes, in the format of `CHANGELOG.md`:

                        ## 8.4.0

                        #### Add
                        - `ImagePrefetcher` reports the progress of each source. #2391
                        - On visionOS, the memory cache follows the system's memory warnings. #2380

                        #### Fix
                        - Cancelling a prefetch no longer leaves its sources in the pending list. #2398
                        - Animated GIFs with a frame duration of zero play at 10 frames per second, as browsers do. #2386

                        Should I add them to the top of `CHANGELOG.md`?
                    """.trimIndent(), ago(6.0)),
                    completed(482_000, ago(6.0)),
                    status("idle", ago(6.0)),
                ),
            ago(14.0),
        )
    }

    /** Idle: Claude Code reviewed a branch a while ago. */
    private fun idlePane(ago: (Double) -> Instant) = DemoPane(
        PaneID.IDLE, "Review sidebar groups", "Prowl", "mint", 0, prowl, "claude",
    ).apply {
        append(
            opening(obj("id" to "3b9d77a0-demo", "cwd" to prowl.path, "model" to "claude-opus-5-5"),
                "Review the sidebar groups change on this branch. Focus on drag-and-drop edge cases. Don't edit files.",
                ago(58.0)) +
                tool(start("p1", "Bash", "shell", "Show the changed files", command = "git diff --stat origin/main...HEAD"),
                    listOf(
                        " App/Sources/Features/Sidebar/SidebarLayout.swift       | 142 ++++++++++----",
                        " App/Sources/Features/Sidebar/SidebarDropDelegate.swift |  88 +++++++--",
                        " App/Tests/Sidebar/SidebarLayoutTests.swift             | 121 ++++++++++++",
                        " 3 files changed, 301 insertions(+), 50 deletions(-)",
                    ).joinToString("\n"), ago(57.5)) +
                tool(start("p2", "Read", "read", "Read the layout", path = "App/Sources/Features/Sidebar/SidebarLayout.swift"),
                    "Read 388 lines", ago(57.0)) +
                tool(start("p3", "Read", "read", "Read the drop delegate",
                    path = "App/Sources/Features/Sidebar/SidebarDropDelegate.swift"), "Read 204 lines", ago(56.5)) +
                listOf(
                    reasoning(9000, ago(56.0)),
                    final("""
                        I found two problems and one smaller point.

                        | # | Severity | Finding | Where |
                        | --- | --- | --- | --- |
                        | 1 | High | Dropping a group on its own repository removes it. | `SidebarDropDelegate.swift:132` |
                        | 2 | Medium | A drop below the last group lands inside it. | `SidebarLayout.swift:217` |
                        | 3 | Low | `move(_:to:)` saves the layout once for each moved item. | `SidebarLayout.swift:164` |

                        For the first one, refuse the drop when the target is inside the dragged group:

                        ```swift
                        guard !layout.contains(target, inGroup: dragged) else {
                          return DropProposal(operation: .forbidden)
                        }
                        ```

                        The tests cover reordering, but not drops into a group's own repositories. I'd add one test for each of the first two cases.
                    """.trimIndent(), ago(41.0)),
                    completed(1_020_000, ago(41.0)),
                    status("idle", ago(41.0)),
                ),
            ago(58.0),
        )
        // Looked at on the Mac already, so idle rather than done.
        setDisplayState("idle")
    }

    /** Two shells. */
    private fun shellPanes(ago: (Double) -> Instant): List<DemoPane> {
        val prowlShell = DemoPane(PaneID.PROWL_SHELL, "zsh", "Prowl", "mint", 0, prowl, null).apply {
            shell += listOf(
                prowl.shellPrompt + "git status --short",
                " M App/Sources/Features/Sidebar/SidebarLayout.swift",
                " M App/Sources/Features/Sidebar/SidebarDropDelegate.swift",
                prowl.shellPrompt + "git log --oneline -3",
                "4f2a91c Keep the group order when a repository moves",
                "b81e0d7 Add sidebar group colors",
                "1c5f3a8 Update the changelog",
                prowl.shellPrompt,
            )
            setStateChangedAt(ago(90.0))
        }
        val kingfisherShell = DemoPane(PaneID.KINGFISHER_SHELL, "swift test", "Kingfisher", "blue", 1, kingfisher, null).apply {
            shell += listOf(
                kingfisher.shellPrompt + "swift test --parallel",
                "Building for debugging...",
                "[312/312] Linking KingfisherPackageTests",
                "Build complete! (38.21s)",
                "Test Suite 'All tests' started.",
                "Test Suite 'All tests' passed.",
                "\t Executed 1046 tests, with 0 failures (0 unexpected) in 42.784 seconds",
                kingfisher.shellPrompt,
            )
            setStateChangedAt(ago(30.0))
        }
        return listOf(prowlShell, kingfisherShell)
    }
}
