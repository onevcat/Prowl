import Testing

@testable import supacode

struct ScreenHeuristicsTests {
  @Test func unknownAgentIsUnknown() {
    let agent: DetectedAgent? = nil
    #expect(agent?.detectState(in: "Working...") ?? .unknown == .unknown)
  }

  @Test func piDetection() {
    #expect(DetectedAgent.pi.detectState(in: "Working...") == .working)
    #expect(DetectedAgent.pi.detectState(in: "Done") == .idle)
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

  @Test func codexDetection() {
    #expect(DetectedAgent.codex.detectState(in: "press enter to confirm or esc to cancel") == .blocked)
    #expect(DetectedAgent.codex.detectState(in: "• Working (12s)\nesc to interrupt") == .working)
    #expect(DetectedAgent.codex.detectState(in: "Ready for input") == .idle)
  }

  @Test func codexDetectionUsesRecentScreenTailWhenScrollbackIsLong() {
    let screen = ((1...80).map { "historical output \($0)" } + ["• Working (12s)", "esc to interrupt"])
      .joined(separator: "\n")

    #expect(agentDetectionRecentText(screen, limit: 2) == "• Working (12s)\nesc to interrupt")
    #expect(DetectedAgent.codex.detectState(in: screen) == .working)
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
}
