import Testing

@testable import supacode

struct ScreenHeuristicsTests {
  @Test func unknownAgentIsUnknown() {
    let agent: DetectedAgent? = nil
    #expect(agent?.detectState(in: "Working...") ?? .unknown == .unknown)
  }

  @Test func piDetection() {
    #expect(DetectedAgent.pi.detectState(in: "Working...") == .working)
    #expect(DetectedAgent.pi.detectState(in: "Interrupting…") == .working)
    #expect(DetectedAgent.pi.detectState(in: "Done") == .idle)
  }

  @Test func ompDetectionUsesItsOwnRuntimeChrome() {
    #expect(DetectedAgent.omp.detectState(in: "Working… ⟦esc⟧") == .working)
    #expect(DetectedAgent.omp.detectState(in: "Reading files ⟨esc⟩") == .working)
    #expect(DetectedAgent.omp.detectState(in: "Done") == .idle)
  }

  @Test func ompAskPromptIsBlockedWithoutChangingPiSemantics() {
    let prompt = """
      ⠏ Clarifying combined list order ⟨esc⟩

      ╭─ Ask ─────────────────────────────────────────────────────────────────────╮
      │ Which order should the combined list use?                                  │
      ├────────────────────────────────────────────────────────────────────────────┤
      │   Repo first                                                             │
      │    Global first                                                           │
      ├────────────────────────────────────────────────────────────────────────────┤
      │ Enter select · n note · ↑/↓ move · Esc cancel                              │
      ╰────────────────────────────────────────────────────────────────────────────╯
      """
    #expect(
      DetectedAgent.omp.detectState(in: prompt) == .blocked
    )
    #expect(DetectedAgent.pi.detectState(in: prompt) == .idle)
  }

  @Test func ompIgnoresStaleWorkingMentionInCompletedOutput() {
    #expect(
      DetectedAgent.omp.detectState(
        in: """
          2. 增强 Pi / Oh My Pi 的屏幕状态判断
             - 原来 Pi 只认 Working...
             - 现在还认：
               - Working…
               - Interrupting…
               - 底部 5 行中以 ⟦esc⟧ / ⟨esc⟩ / [esc] 结尾、且前面有内容的行
             - 这些都会判定为 .working。
             - 其他情况仍然是 .idle。

          结论：这是一个很聚焦的 branch，目的就是让 Prowl 正确识别 Oh My Pi，并显示 Pi 图标与 working 状态。

           857   685  cache: 45K
          ╭──     GPT-5.5 ·  high   ~/Sync/github/Prowl   add-oh-my-pi-agent ──╮
          ╰─
          """
      ) == .idle
    )
  }

  @Test func ompDetectsActiveSpinnerEvenWhenStatusPanelFollows() {
    #expect(
      DetectedAgent.omp.detectState(
        in: """
          After I add a failing test case, I should edit the code accordingly.
          It’s important to reproduce the error first, then run the Swift tests after the edits.

           980   571  cache: 50K

          ┌───  Todo 5 tasks ─────────────────────────────────────────────────────┐
          │ I. Investigation                                                       │
          │   ├─  Reproduce stale working state                                   │
          │   └─  Trace Pi heuristic cause                                        │
          │ II. Fix                                                                │
          │   ├─  Add failing regression test                                     │
          │   ├─  Tighten Pi working detection                                    │
          │   └─  Run relevant verification                                       │
          └────────────────────────────────────────────────────────────────────────┘

          ⠹ Updating progress ⟨esc⟩

            Todos
            └ II. Fix
            └  Add failing regression test
               Tighten Pi working detection
               Run relevant verification
          """
      ) == .working
    )
  }

  @Test func claudeDetection() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Reading file
          ✽ Tempering…
          ─────────
          ❯
          ─────────
          """
      ) == .working
    )
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Do you want to proceed?
          ❯ 1. Yes
            2. No

          Esc to cancel · Tab to amend
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Task complete.
          ─────────
          ❯
          ─────────
          """
      ) == .idle
    )
  }

  @Test func claudeIgnoresStalePermissionPromptNearCurrentIdlePrompt() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Do you want to proceed?
          ❯ 1. Yes
            2. No

          Completed line 1
          Completed line 2
          Completed line 3
          Completed line 4
          Completed line 5
          Completed line 6
          Completed line 7
          Completed line 8
          Completed line 9
          Completed line 10
          Completed line 11
          Completed line 12
          Task complete.
          ─────────
          ❯
          ─────────
          """
      ) == .idle
    )
  }

  @Test func claudeIgnoresStalePermissionPromptOutsideRecentTail() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Do you want to proceed?
          ❯ 1. Yes
            2. No

          Completed line 1
          Completed line 2
          Completed line 3
          Completed line 4
          Completed line 5
          Completed line 6
          Completed line 7
          Completed line 8
          Completed line 9
          Completed line 10
          Completed line 11
          Completed line 12
          Completed line 13
          Completed line 14
          Completed line 15
          Completed line 16
          Completed line 17
          Completed line 18
          Completed line 19
          Completed line 20
          Completed line 21
          Completed line 22
          Completed line 23
          Completed line 24
          Task complete.
          ─────────
          ❯
          ─────────
          """
      ) == .idle
    )
  }

  @Test func claudeDetectsBlockedWhenFirstOptionSelectedInLongMenu() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          需要决策：/release 跳进去发现 APK 没有链时，怎么走接？

          ❯ 1. 自动 release: scripts/build-bridge.sh (Recommended)
              /release 路径检及发现 APK 类失败链通，自动执行 build-bridge.sh 后继续。
              便交不会进入入想运能走链。
              缺点: /release 隐含使用 JDK + Android SDK
              清看的语述置自动应才进。
            2. Pre-flight 重新链: 不动动作
              Step 1: 检查相关 /release 提示具子选定有应作 build-bridge.sh，从是
              scripts/build-bridge.sh。
              缺点: 严格、明确、不会有什么动作，但有手动确认。
            3. Pre-flight 只检查: 例丁检发标
              选择 APK 检证，看丁路否构建？[Y/n]
              确即标当链全式动连验。
            4. Type something.
            5. Chat about this
          ──────────────────────────────────────────────────────────────────────────────
            [Opus 4.7 (1M context) | Max] █░░░░░░░░░ 8% | Prowl git:(branch*) | 2 CLAUDE.md
            ⏵⏵ bypass permissions on (shift+tab to cycle)
          """
      ) == .blocked
    )
  }

  @Test func claudeDoesNotTreatHistoryInputAndBranchNameAsPermissionPrompt() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          ✻ Crunched for 10s

          ❯ 切一下fix/nocilla-thread-safe-stubs

          ⏺ Bash(git checkout fix/nocilla-thread-safe-stubs)
            ⎿  切换到分支 'fix/nocilla-thread-safe-stubs'
               您的分支基于 'origin/fix/nocilla-thread-safe-stubs'，但此上游分支已经不存在。
                 （使用 "git branch --unset-upstream" 来修复）

          ⏺ 喵～切过来了！不过有个小提醒喵：

            - 当前分支：fix/nocilla-thread-safe-stubs ✅
            - ⚠️ 上游 origin/fix/nocilla-thread-safe-stubs 已经不存在了喵

            要不要喵帮忙处理一下？可选：
            1. git branch --unset-upstream —— 解除失效的上游绑定喵
            2. 看一下这个分支跟 master 的差异，确认是否还需要保留
            3. 如果确认没用了，可以切回 master 后删除喵

            主子想怎么处理喵？

          ✻ Churned for 8s
          """
      ) == .idle
    )
  }

  @Test func claudeViewerChromeAtBottomCarriesNoSignal() {
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          ✻ Tempering… (12s · esc to interrupt)
          older transcript content
          ctrl+r to toggle
          """
      ) == .unknown
    )
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Task complete.
          ⌕ Search…
          ↑↓ to navigate
          """
      ) == .unknown
    )
  }

  @Test func claudeQuotedViewerHintMidConversationDoesNotForceIdle() {
    // Regression: a chat message quoting "ctrl+r to toggle" used to force
    // idle while the spinner below showed Claude still working.
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          ⏺ 收尾完成,现状如下:

          ❯ 3. 修一个我们现存的 bug:detectClaude 里 ctrl+r to toggle → 强制 idle,意味着
            Claude working 时按 ctrl+o/ctrl+r 看 transcript 会闪成 Done。

            这个仔细看看，你觉得有必要的话，可以修一下

          ✻ Twisting… (34s · ↓ 1.8k tokens · thinking more with xhigh effort)
          ─────────
          ❯
          ─────────
          """
      ) == .working
    )
  }

  @Test func claudeDetectsRunningWorkflowFooterBelowPrompt() {
    // A running background workflow: the turn has ended (no spinner / "esc to
    // interrupt" above the prompt), but Claude keeps a status line BELOW the
    // input box. The "<done>/<total> agents done" segment marks active work.
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          ⏺ Kicked off the scout workflow in the background.
          ─────────
          ❯
          ─────────
          ◯ scout-prowl-idle  Map idle detection   3/5 agents done · 7m 29s · ↓ 288.5k tokens
          """
      ) == .working
    )
    // Idle with an ordinary footer (no workflow line) stays idle.
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          Task complete.
          ─────────
          ❯
          ─────────
          ? for shortcuts
          """
      ) == .idle
    )
    // The marker quoted in conversation (above the prompt) must NOT force
    // working — the check is anchored to the below-prompt footer.
    #expect(
      DetectedAgent.claude.detectState(
        in: """
          ⏺ The run showed 3/5 agents done before it wrapped up.
          ─────────
          ❯
          ─────────
          ? for shortcuts
          """
      ) == .idle
    )
  }

  /// Live captures. The word after the glyph is randomized between renders, so the
  /// elapsed counter following it is the part that marks a turn as still in flight.
  @Test func statusLineWithElapsedCounterIsWorking() {
    let lines = [
      "● Forging… (10s · thinking with high effort)",
      "● Forming… (8s · ↓ 330 tokens · thinking with high effort)",
      "● Grooving… (2s · thinking with high effort)",
    ]
    for line in lines {
      #expect(
        DetectedAgent.claude.detectState(
          in: """
            \(line)
            ─────────
            ❯
            ─────────
            """
        ) == .working
      )
    }
  }

  /// Message bullets share the leading glyph and routinely end a clause with an
  /// ellipsis, so the counter is the only thing separating a finished turn from a
  /// running one. Without it these must stay idle.
  @Test func bulletedMessageWithoutElapsedCounterIsIdle() {
    let lines = [
      "● I checked the file… it looks fine to me",
      "● Done… (see above)",
    ]
    for line in lines {
      #expect(
        DetectedAgent.claude.detectState(
          in: """
            \(line)
            ─────────
            ❯
            ─────────
            """
        ) == .idle
      )
    }
  }

  /// The existing header check matches the literal verb `Working`, so a reworded
  /// status line only registers through the shared elapsed-counter shape.
  @Test func codexStatusLineWithRewordedVerbIsWorking() {
    #expect(DetectedAgent.codex.detectState(in: "• Exploring… (12s · 4 tool calls)") == .working)
    #expect(DetectedAgent.codex.detectState(in: "• Reticulating (3m · 12 files)") == .working)
    #expect(DetectedAgent.codex.detectState(in: "• Ready for your input") == .idle)
  }

  @Test func codexDetection() {
    #expect(DetectedAgent.codex.detectState(in: "press enter to confirm or esc to cancel") == .blocked)
    #expect(DetectedAgent.codex.detectState(in: "• Working (12s)\nesc to interrupt") == .working)
    #expect(DetectedAgent.codex.detectState(in: "Ready for input") == .idle)
  }

  @Test func geminiDetection() {
    #expect(DetectedAgent.gemini.detectState(in: "│ Apply this change") == .blocked)
    #expect(DetectedAgent.gemini.detectState(in: "esc to cancel") == .working)
    #expect(DetectedAgent.gemini.detectState(in: "done") == .idle)
  }

  @Test func cursorDetection() {
    #expect(DetectedAgent.cursor.detectState(in: "Run command? (y) (enter)") == .blocked)
    #expect(
      DetectedAgent.cursor.detectState(
        in: """
          Run this command?
          Not in allowlist: git log --oneline --decorate -n 8
           → Run (once) (y)
             Add Shell(git log) to allowlist? (tab)
             Auto-run everything (shift+tab)
             Skip (esc or n)
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.cursor.detectState(
        in: """
          ⚠ Workspace Trust Required
          Cursor Agent can execute code and access files in this directory.
          [a] Trust this workspace
          [q] Quit
          """
      ) == .blocked
    )
    #expect(DetectedAgent.cursor.detectState(in: "⏳ Trusting workspace...") == .working)
    #expect(DetectedAgent.cursor.detectState(in: "⬡ indexing") == .working)
    #expect(
      DetectedAgent.cursor.detectState(
        in: """
          The docs mention pressing (y) to allow a run.
          This is historical output, not a prompt.
          """
      ) == .idle
    )
    #expect(DetectedAgent.cursor.detectState(in: "Skip (esc or n)") == .idle)
    #expect(DetectedAgent.cursor.detectState(in: "done") == .idle)
  }

  @Test func clineDetection() {
    #expect(DetectedAgent.cline.detectState(in: "Let Cline use this tool? yes") == .blocked)
    #expect(
      DetectedAgent.cline.detectState(
        in: """
          ⏺ 我已准备好开始。你现在希望我帮你做什么？
            1. 实现一个新功能
            2. 排查/修复一个 bug
          ╭───╮
          │ (1-5 or type)                                                           │
          ╰───╯
           / for commands · @ for files
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.cline.detectState(
        in: """
          ⠋ Acting... (3s · esc to interrupt)
          💡 Tip: Use /skills to browse and attach reusable skill files.
          ╭───╮
          │                                                                         │
          ╰───╯
           / for commands · @ for files
          """
      ) == .working
    )
    #expect(
      DetectedAgent.cline.detectState(
        in: """
          ⏺ Task completed
            你好！👋

                                    Start New Task (1)                       Exit (2)
          ╭───╮
          │                                                                         │
          ╰───╯
           / for commands · @ for files
          """
      ) == .idle
    )
    #expect(DetectedAgent.cline.detectState(in: "Cline is ready for your message") == .idle)
    #expect(DetectedAgent.cline.detectState(in: "Start New Task (1)") == .idle)
  }

  @Test func opencodeDetection() {
    #expect(DetectedAgent.opencode.detectState(in: "△ Permission required") == .blocked)
    #expect(
      DetectedAgent.opencode.detectState(
        in: """
          Run command?
          ↑↓ select  ⇆ tab  enter confirm  esc dismiss
          """
      ) == .blocked
    )
    #expect(DetectedAgent.opencode.detectState(in: "esc to interrupt") == .working)
    #expect(DetectedAgent.opencode.detectState(in: "Do you want to continue?\nYes") == .idle)
    #expect(DetectedAgent.opencode.detectState(in: "done") == .idle)
  }

  @Test func copilotDetection() {
    #expect(DetectedAgent.copilot.detectState(in: "│ do you want to run this?") == .blocked)
    #expect(DetectedAgent.copilot.detectState(in: "esc to cancel") == .working)
    #expect(DetectedAgent.copilot.detectState(in: "Do you want to continue?\nYes") == .idle)
    #expect(DetectedAgent.copilot.detectState(in: "done") == .idle)
  }

  @Test func kimiDetection() {
    #expect(DetectedAgent.kimi.detectState(in: "approve? [y/n]") == .blocked)
    #expect(DetectedAgent.kimi.detectState(in: "thinking") == .working)
    #expect(DetectedAgent.kimi.detectState(in: "ctrl-c to cancel") == .working)
    #expect(DetectedAgent.kimi.detectState(in: "🌘") == .working)
    #expect(DetectedAgent.kimi.detectState(in: "⠸ Using Shell (git status)") == .working)
    #expect(
      DetectedAgent.kimi.detectState(
        in: """
          ⠋ Using Shell (git remote -v)
          \(String(repeating: "\n", count: 40))
          ─────────────────────────────────────────────────────────────────────
          agent (kimi-k2.5 ●)  ~/Sync/github/Prowl  feat/active-agents-pa…  ctrl-o: editor
                                                    context: 6.5% (17k/262.1k)
          """
      ) == .working
    )
    #expect(
      DetectedAgent.kimi.detectState(
        in: """
          ── input ────────────────────────────────────────────────────────────
          \(String(repeating: "\n", count: 40))
          ─────────────────────────────────────────────────────────────────────
          agent (kimi-k2.5 ●)  ~/Sync/github/Prowl  feat/active-agents-pa…  ctrl-o: editor
                                                    context: 6.5% (17k/262.1k)
          """
      ) == .idle
    )
    #expect(
      DetectedAgent.kimi.detectState(
        in: """
          ⠸ Using Shell (git remote -v && echo "--..." && git log --oneline -3)
          ╭─ approval ─────────────────────────────────────────────────────────╮
          │  Shell is requesting approval to run command:                      │
          │                                                                    │
          │ → [1] Approve once                                                 │
          │   [2] Approve for this session                                     │
          │   [3] Reject                                                       │
          │   [4] Reject, tell the model what to do instead                    │
          │                                                                    │
          │   ▲/▼ select  1/2/3/4 choose  ↵ confirm                            │
          ╰────────────────────────────────────────────────────────────────────╯
          \(String(repeating: "\n", count: 40))
          ─────────────────────────────────────────────────────────────────────
          agent (kimi-k2.5 ●)  ~/Sync/github/Prowl  feat/active-agents-pa…  ctrl-o: editor
                                                    context: 6.5% (17k/262.1k)
          """
      ) == .blocked
    )
    #expect(DetectedAgent.kimi.detectState(in: "done") == .idle)
  }

  @Test func droidDetection() {
    #expect(DetectedAgent.droid.detectState(in: "EXECUTE\nenter to select") == .blocked)
    #expect(DetectedAgent.droid.detectState(in: "> Yes, allow\n> No, cancel\nUse ↑↓ to navigate") == .blocked)
    #expect(DetectedAgent.droid.detectState(in: "⠋ esc to stop") == .working)
    #expect(DetectedAgent.droid.detectState(in: "esc to stop") == .working)
    #expect(DetectedAgent.droid.detectState(in: "done") == .idle)
  }

  @Test func ampDetection() {
    #expect(
      DetectedAgent.amp.detectState(
        in: """
          Waiting for approval
          Approve
          Allow All for This Session
          """
      ) == .blocked
    )
    #expect(DetectedAgent.amp.detectState(in: "waiting for approval\nallow all for this session") == .idle)
    #expect(DetectedAgent.amp.detectState(in: "esc to cancel") == .working)
    #expect(DetectedAgent.amp.detectState(in: "done") == .idle)
  }

  @Test func qwenDetection() {
    #expect(DetectedAgent.qwen.detectState(in: "Waiting for user confirmation...") == .blocked)
    #expect(
      DetectedAgent.qwen.detectState(
        in: """
          Do you want to proceed?
          > Yes, allow once
            Always allow in this project
            No (esc)
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.qwen.detectState(
        in: """
          ┌─ Shell Command Execution ──────────────────────┐
          │ Do you want to proceed?                        │
          │  > Yes, allow once                             │
          │    No (esc)                                    │
          └────────────────────────────────────────────────┘
          """
      ) == .blocked
    )
    #expect(DetectedAgent.qwen.detectState(in: "⠏ I'm Feeling Lucky (5s · esc to cancel)") == .working)
    #expect(DetectedAgent.qwen.detectState(in: "Thinking... (12s · ctrl+c to cancel)") == .working)
    #expect(DetectedAgent.qwen.detectState(in: "⠸ Writing file... (3s · ↓ 200 tokens · esc to cancel)") == .working)
    #expect(DetectedAgent.qwen.detectState(in: "done") == .idle)
    #expect(DetectedAgent.qwen.detectState(in: "> Type your message") == .idle)
  }

  @Test func qoderCLIDetection() {
    // Exec permission menu captured from a live Qoder CLI 1.0.48 session; the
    // second row is dynamic ("Always allow \"<cmd>\" for future sessions"),
    // so detection must not require "Allow for this session".
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
           Permission Required
           Tool: Bash
           Command: echo hello > /tmp/qoder_perm_test.txt
           Allow this command to run? Redirection detected.
            ❯ 1. Allow once
              2. Always allow "echo" for future sessions [local]
              3. Reject and type something
              4. No
          """
      ) == .blocked
    )
    // Edit-style menu keeps the session-scoped row.
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
           ❯ 1. Allow once
             2. Allow for this session
             3. Reject and type something
             4. No
          """
      ) == .blocked
    )
    // Ask-user question dialog (live capture): dynamic options plus the fixed
    // "Type Something" row under an "Asking User" header.
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
           Asking User
           Which color do you prefer?
            ❯ 1. Red
              2. Blue
              3. Type Something
           ↑↓ navigate · Enter select · Esc back
          """
      ) == .blocked
    )
    // Plan-ready dialog (live capture).
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
          Qoder has written up a plan and is ready to execute. Would you like to proceed?
           ❯ 1. Yes, start executing
             2. Yes, execute as Goal (auto)
             3. Refuse and say something
             4. Reject plan
          Ctrl+X to edit plan
          """
      ) == .blocked
    )
    // Working footer stays detected with the full input-box chrome below it
    // (live capture: 6 persistent footer lines under the spinner).
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
           ⠹ Thinking... (esc to cancel, 2s)
          ─────────────────────────────
           Shift+Tab to Accept Edits
          ─────────────────────────────
           >   Type your message or @path/to/file
          ─────────────────────────────
           Ultimate Model · ctx ░░░░░░░░░░ 0% · ~/Sync/github/Prowl
          """
      ) == .working
    )
    // Resolved dialogs vanish entirely (ephemeral overlays); the transcript
    // only keeps the tool row, so a finished screen is idle.
    #expect(
      DetectedAgent.qoder.detectState(
        in: """
           x Bash(echo hello > /tmp/qoder_perm_test.txt)
             └ User cancelled.
          ─────────────────────────────
           Shift+Tab to Accept Edits
          ─────────────────────────────
           >   Type your message or @path/to/file
          ─────────────────────────────
           Ultimate Model · ctx ▓▓░░░░░░░░ 17% · ~/Sync/github/Prowl
          """
      ) == .idle
    )
    // Single labels in prose must not block; a quoted footer without the
    // braille spinner must not read as working.
    #expect(DetectedAgent.qoder.detectState(in: "Allow once\nNo") == .idle)
    #expect(DetectedAgent.qoder.detectState(in: "Thinking... (esc to cancel, 12s)") == .idle)
  }

  @Test func grokDetection() {
    // Permission chrome (labels verified against Grok Build 0.2.101 binary).
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          Allow once
          Always allow this command
          Always allow on all sessions
          Reject
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          Yes, and always allow this exact command
          Yes, allow all edits
          """
      ) == .blocked
    )
    // Incomplete permission chrome must not trip blocked.
    #expect(DetectedAgent.grok.detectState(in: "Allow once") == .idle)
    #expect(DetectedAgent.grok.detectState(in: "please approve the design") == .idle)

    #expect(
      DetectedAgent.grok.detectState(
        in: """
          Pending: question
          Which approach should we take?
          """
      ) == .blocked
    )
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          Awaiting your input
          Pick an option?
          ↑↓ select
          """
      ) == .blocked
    )

    #expect(DetectedAgent.grok.detectState(in: "Loading") == .working)
    #expect(DetectedAgent.grok.detectState(in: "Loading… streaming response") == .working)
    #expect(DetectedAgent.grok.detectState(in: "deferred: tool calls in flight") == .working)
    #expect(DetectedAgent.grok.detectState(in: "Working tools") == .working)
    #expect(DetectedAgent.grok.detectState(in: "These tasks are still running:") == .working)
    #expect(DetectedAgent.grok.detectState(in: "⠋ Reading AgentClassifier.swift") == .working)
    #expect(DetectedAgent.grok.detectState(in: "✱ Searching… codebase") == .working)

    #expect(DetectedAgent.grok.detectState(in: "Awaiting input") == .idle)
    #expect(DetectedAgent.grok.detectState(in: "Awaiting your input") == .idle)
    #expect(DetectedAgent.grok.detectState(in: "Type a message") == .idle)
    #expect(DetectedAgent.grok.detectState(in: "done") == .idle)
  }

  // Fixtures below are verbatim screen captures from Grok Build 0.2.101
  // running inside a Prowl pane.
  @Test func grokDetectionMatchesCapturedDialogChrome() {
    // Bash tool approval — no "Allow once" / "Always allow …" rows here.
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          ◆ Sleep 12s then print DONE_MARKER… 51s                    52s ⇣21.1k [↓][stop]
          ┃  Sleep 12s then print DONE_MARKER
          ┃  sleep 12 && echo DONE_MARKER
          ┃
          ┃  1 (●) Yes, and don't ask again for anything (always-approve mode)
          ┃  2 (○) Yes, proceed
          ┃  3 (○) No, reject (type to add feedback)
          ┃
          1/3:select  │  Ctrl+o:always-approve  │  Ctrl+c:cancel
          """
      ) == .blocked
    )
    // File-edit approval.
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          ┃  Allow Edit to /tmp/grok_probe.txt?
          ┃
          ┃  1 (○) Yes, and don't ask again for anything (always-approve mode)
          ┃  2 (○) Yes, allow all edits during this session
          ┃  3 (○) Yes
          ┃  4 (●) No, reject (type to add feedback)
          ┃
          1/4:select  │  Ctrl+o:always-approve  │  Ctrl+c:cancel
          """
      ) == .blocked
    )
    // Ask-user question dialog.
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          ◆ Waiting on answers for When working in this repo, which response style do you prefer?
          ┃  When working in this repo, which response style do you prefer?
          ┃
          ┃  1 (○) Concise                 Short answers, minimal explanation unless needed
          ┃  2 (○) Balanced (Recommended)  Brief conclusion plus key reasoning when useful
          ┃  z (○) Type your answer here
          ┃
          ┃  ↑/↓ navigate · y copy                                        Enter:submit
          Esc:unselect  │  Tab:scrollback  │  Shift+x:dismiss
          """
      ) == .blocked
    )
    // Streaming / tool-execution status lines use a braille spinner.
    #expect(DetectedAgent.grok.detectState(in: "⠧ Waiting for response… 0.0s        0.0s ⇣20.9k [stop]") == .working)
    #expect(DetectedAgent.grok.detectState(in: "⠦ Thinking… 0.2s                    1.0s ⇣21.0k [stop]") == .working)
    #expect(
      DetectedAgent.grok.detectState(
        in: "⠙ Sleep 12s then print DONE_MARKER… 20s                21s ⇣21.3k [↓][stop]"
      ) == .working
    )
    // Idle prompt: input frame, model label, shortcut footer.
    #expect(
      DetectedAgent.grok.detectState(
        in: """
          ╭──────────────────────────────────────────────╮
          │ ❯                                            │
          ╰────────────────────────────── Grok 4.5 (high) ─╯
          Shift+Tab:mode  │  Ctrl+x:shortcuts
          """
      ) == .idle
    )
    // Completed-turn summary in scrollback stays idle.
    #expect(DetectedAgent.grok.detectState(in: "Worked for 3.6s.                stop  [hooks: 1]") == .idle)
    // A lone yes-row in transcript prose must not read as an approval dialog.
    #expect(DetectedAgent.grok.detectState(in: "The user said yes, proceed with the plan.") == .idle)
    #expect(DetectedAgent.grok.detectState(in: "I chose to reject the first approach.") == .idle)
  }
}
