// supacode/Domain/Workflow/WorkflowStarterTemplate.swift
// The file Settings › Workflows › "New Workflow…" writes (docs-ai 063 D1): a small, valid
// two-role workflow whose comments point at the validator and the bundled skill. The id is
// the file's stem so several starters never shadow each other.

import Foundation

nonisolated enum WorkflowStarterTemplate {
  static let fileStem = "new-workflow"

  static func yaml(id: String) -> String {
    """
    # A Prowl Agent Workflow (schema prowl.workflow/v1).
    # Check it with `prowl workflow validate <this file>`; a validated file is runnable from
    # the Command Palette ("Run Workflow: …"), the toolbar Agents menu, or `prowl workflow run`.
    # The bundled prowl-workflow skill (`prowl skills install prowl-workflow`) teaches an agent
    # to write and run these; `prowl workflow schema` prints the full reference.
    schema: prowl.workflow/v1
    id: \(id)                      # lowercase slug, unique across your workflows
    name: New Workflow
    description: Ask a second agent to review what this pane is working on.
    # icon: magnifyingglass.circle  # optional SF Symbol shown by the entry points

    inputs:
      focus:
        type: string
        default: ""
        prompt: What should the reviewer focus on?

    roles:
      author:
        source: current            # the pane the run is started from
      reviewer:
        source: launch             # a new agent Prowl launches from an Agent Profile
        bind: ask                  # ask (choose the profile at start) | auto (use the remembered one)
        placement: split
        direction: right

    steps:
      - id: brief
        title: Author writing the brief
        message: author
        instruction: |
          Write a short brief for a reviewer: what changed, what you are unsure about, and how
          to verify it. Focus: {{ inputs.focus }}
          Deliver the brief with the generated completion command.
        expect: { output: brief }

      - id: review
        title: Reviewer checking the work
        launch: reviewer
        prompt: |
          Read {{ outputs.brief.path }} and review the work it describes in this worktree.
          Report under "## Findings" and end with "## Verdict".
        expect: { output: findings, sections: ["## Findings", "## Verdict"], verdict: [clean, issues] }

      - id: done
        notify: "Review finished: {{ outputs.findings.verdict }}"

    """
  }

  /// `new-workflow.yaml`, then `new-workflow-2.yaml`, … — the first name no file uses.
  static func uniqueFileURL(in directory: URL, fileManager: FileManager = .default) -> URL {
    var attempt = 1
    while true {
      let stem = attempt == 1 ? fileStem : "\(fileStem)-\(attempt)"
      let url = directory.appending(path: "\(stem).yaml", directoryHint: .notDirectory)
      if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
      attempt += 1
    }
  }

  /// Creates the directory when needed and writes a starter whose id is the file's stem.
  static func write(in directory: URL, fileManager: FileManager = .default) throws -> URL {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = uniqueFileURL(in: directory, fileManager: fileManager)
    try Data(yaml(id: url.deletingPathExtension().lastPathComponent).utf8).write(to: url, options: .atomic)
    return url
  }
}
