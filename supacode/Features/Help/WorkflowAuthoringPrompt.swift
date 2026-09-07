import Foundation
import ProwlCLIShared

/// The copyable prompt behind Settings › Agents › Workflows › "Ask an Agent…" (docs-ai 063
/// D1): it points a coding agent at the bundled `prowl-workflow` skill and the workflows
/// manual, and asks it to author, validate, and place a workflow bundle. Localized like
/// `AskAgentHelpPrompt`; pure so it is unit-testable.
nonisolated enum WorkflowAuthoringPrompt {
  static func strings(
    skillPath: String,
    manualPath: String,
    workflowsDirectory: String,
    locale: Locale = AskAgentHelpPrompt.systemPreferredLocale()
  ) -> AskAgentHelpStrings {
    switch AskAgentHelpPrompt.languageKey(for: locale) {
    case .english:
      return english(skill: skillPath, manual: manualPath, directory: workflowsDirectory)
    case .simplifiedChinese:
      return simplifiedChinese(skill: skillPath, manual: manualPath, directory: workflowsDirectory)
    case .traditionalChinese:
      return traditionalChinese(skill: skillPath, manual: manualPath, directory: workflowsDirectory)
    case .japanese:
      return japanese(skill: skillPath, manual: manualPath, directory: workflowsDirectory)
    }
  }

  private static func english(skill: String, manual: String, directory: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "Ask an agent to write a workflow",
      explanation:
        "Copy this prompt and paste it into your coding agent (Claude Code, Codex, …) in a "
        + "terminal. It points the agent at the bundled workflow skill and manual and asks it to "
        + "write, validate, and place a workflow bundle for you.",
      prompt: """
        Write a Prowl Agent Workflow for me.

        Prowl runs multi-agent workflows from .pwlworkflow bundles containing workflow.yaml \
        (schema prowl.workflow/v1). The authoring guide and feature manual ship inside the app:

        - Skill:  \(skill)
        - Manual: \(manual)

        Read the skill first (it links its references/ files for the full DSL and validator rules). Then:

        1. Ask me what the workflow should do: which agents take part, what each step asks for, \
        and when it ends.
        2. Write a <name>.pwlworkflow directory containing workflow.yaml into \(directory) with a short, unique id.
        3. Validate it with `prowl workflow validate <name>.pwlworkflow` and fix every error.
        4. Tell me how to start it (Command Palette → "Run Workflow: <name>", or `prowl workflow run <id>`).

        Reply in my preferred language.
        """,
      copyButtonTitle: "Copy Prompt",
      copiedButtonTitle: "Copied!",
      doneButtonTitle: "Done"
    )
  }

  private static func simplifiedChinese(skill: String, manual: String, directory: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "让 agent 写一个 workflow",
      explanation:
        "复制这段提示词，粘贴给你在终端里的编码 agent（Claude Code、Codex…）。"
        + "它会让 agent 读取 Prowl 内置的 workflow skill 和说明书，然后替你编写、校验并放置 workflow bundle。",
      prompt: """
        请为我编写一个 Prowl Agent Workflow。

        Prowl 用包含 workflow.yaml 的 .pwlworkflow 目录（schema prowl.workflow/v1）运行多 agent 工作流。编写指南和功能说明书都打包在 app 内：

        - Skill：  \(skill)
        - 说明书： \(manual)

        请先读 skill（它链接了 references/ 下的完整 DSL 和校验规则）。然后：

        1. 问我这个 workflow 要做什么：哪些 agent 参与、每一步要求什么、何时结束。
        2. 用一个简短且唯一的 id，把包含 workflow.yaml 的 <name>.pwlworkflow 目录写到 \(directory)。
        3. 用 `prowl workflow validate <name>.pwlworkflow` 校验，并修复所有错误。
        4. 告诉我怎么启动它（Command Palette → “Run Workflow: <名称>”，或 `prowl workflow run <id>`）。

        请用我的首选语言回答。
        """,
      copyButtonTitle: "复制提示词",
      copiedButtonTitle: "已复制！",
      doneButtonTitle: "完成"
    )
  }

  private static func traditionalChinese(skill: String, manual: String, directory: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "讓 agent 寫一個 workflow",
      explanation:
        "複製這段提示詞，貼給你在終端機裡的編碼 agent（Claude Code、Codex…）。"
        + "它會讓 agent 讀取 Prowl 內建的 workflow skill 和說明書，然後替你撰寫、檢驗並放置 workflow bundle。",
      prompt: """
        請為我撰寫一個 Prowl Agent Workflow。

        Prowl 用包含 workflow.yaml 的 .pwlworkflow 目錄（schema prowl.workflow/v1）執行多 agent 工作流。撰寫指南和功能說明書都打包在 app 內：

        - Skill：  \(skill)
        - 說明書： \(manual)

        請先讀 skill（它連結了 references/ 下的完整 DSL 和檢驗規則）。然後：

        1. 問我這個 workflow 要做什麼：哪些 agent 參與、每一步要求什麼、何時結束。
        2. 用一個簡短且唯一的 id，把包含 workflow.yaml 的 <name>.pwlworkflow 目錄寫到 \(directory)。
        3. 用 `prowl workflow validate <name>.pwlworkflow` 檢驗，並修正所有錯誤。
        4. 告訴我怎麼啟動它（Command Palette → 「Run Workflow: <名稱>」，或 `prowl workflow run <id>`）。

        請用我的首選語言回答。
        """,
      copyButtonTitle: "複製提示詞",
      copiedButtonTitle: "已複製！",
      doneButtonTitle: "完成"
    )
  }

  private static func japanese(skill: String, manual: String, directory: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "エージェントにワークフローを書いてもらう",
      explanation:
        "このプロンプトをコピーして、ターミナルのコーディングエージェント（Claude Code、Codex など）"
        + "に貼り付けてください。Prowl に同梱されたワークフロースキルとマニュアルを読ませ、"
        + "ワークフローバンドルの作成・検証・配置を任せられます。",
      prompt: """
        Prowl の Agent Workflow を書いてください。

        Prowl は workflow.yaml を含む .pwlworkflow ディレクトリ（schema prowl.workflow/v1）で複数エージェントのワークフローを実行します。\
        作成ガイドと機能マニュアルはアプリ内に同梱されています：

        - スキル：     \(skill)
        - マニュアル： \(manual)

        まずスキルを読んでください（references/ 以下に完全な DSL と検証ルールがリンクされています）。そのうえで：

        1. このワークフローで何をしたいか私に確認してください：参加するエージェント、各ステップで求めること、終了条件。
        2. 短くて一意な id を付けて、workflow.yaml を含む <name>.pwlworkflow ディレクトリを \(directory) に書いてください。
        3. `prowl workflow validate <name>.pwlworkflow` で検証し、すべてのエラーを修正してください。
        4. 起動方法を教えてください（Command Palette → 「Run Workflow: <名前>」、または `prowl workflow run <id>`）。

        私の優先言語で回答してください。
        """,
      copyButtonTitle: "プロンプトをコピー",
      copiedButtonTitle: "コピーしました！",
      doneButtonTitle: "完了"
    )
  }
}
