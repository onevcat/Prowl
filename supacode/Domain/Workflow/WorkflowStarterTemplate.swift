// supacode/Domain/Workflow/WorkflowStarterTemplate.swift
// The bundle Settings › Workflows › "New Workflow…" writes (docs-ai 063 D1, 022): a small,
// valid workflow of the kind the user picked, with the name, id, and icon they entered. The
// comments explain the file to someone who edits it by hand and point at the bundled manual
// and skill; the id is the folder's stem so several starters never shadow each other.

import Foundation
import ProwlCLIShared

nonisolated enum WorkflowStarterTemplate {
  /// The two shapes the New Workflow form offers.
  enum Kind: String, Equatable, Sendable, CaseIterable {
    /// One instruction to the agent in the current pane — a prompt template.
    case singleAgent
    /// Several agents that hand results to each other, like a handoff or a cross review.
    case multiAgent
  }

  /// Where the bundled documentation lives on this machine, for the template's comments.
  struct Documentation: Equatable, Sendable {
    var manualPath: String
    var skillPath: String

    static let standard = Documentation(
      manualPath: "/Applications/Prowl.app/Contents/Resources/docs/components/workflows.md",
      skillPath: "/Applications/Prowl.app/Contents/Resources/skills/prowl-workflow/SKILL.md")
  }

  struct Request: Equatable, Sendable {
    var name: String
    var id: String
    /// An SF Symbol name; nil leaves the icon line commented out.
    var icon: String?
    var kind: Kind
    var documentation: Documentation = .standard

    var fileName: String { "\(id).pwlworkflow" }
  }

  static func yaml(_ request: Request) -> String {
    switch request.kind {
    case .singleAgent: singleAgent(request)
    case .multiAgent: multiAgent(request)
    }
  }

  /// A workflow id the schema accepts, derived from a display name: lowercase words joined by
  /// dashes. Empty when the name has no usable character.
  static func suggestedID(for name: String) -> String {
    let lowered = name.lowercased()
    var slug = ""
    var pendingDash = false
    for scalar in lowered.unicodeScalars {
      if scalar.properties.isAlphabetic && scalar.isASCII || ("0"..."9").contains(scalar) {
        if pendingDash, !slug.isEmpty { slug.append("-") }
        pendingDash = false
        slug.unicodeScalars.append(scalar)
      } else {
        pendingDash = true
      }
    }
    return String(slug.prefix(64))
  }

  /// Writes the starter as `<id>.pwlworkflow/workflow.yaml`, creating the directory when needed.
  /// Fails when a bundle with that name already exists: the form checks first, and the file
  /// system decides last.
  static func write(_ request: Request, in directory: URL, fileManager: FileManager = .default) throws -> URL {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: request.fileName, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    try Data(yaml(request).utf8).write(to: url.appending(path: "workflow.yaml"), options: .atomic)
    return url
  }

  private static func header(_ request: Request, explanation: String) -> String {
    """
    # A Prowl Agent Workflow (schema prowl.workflow/v1).
    #
    \(explanation)
    #
    # Manual: \(request.documentation.manualPath)
    # Skill:  \(request.documentation.skillPath)
    #         (teaches a coding agent to write, validate, and run workflows)
    # Check:  prowl workflow validate <this folder>
    """
  }

  private static func identity(_ request: Request, description: String, iconHint: String) -> String {
    let icon = request.icon.map { "icon: \(yamlString($0))" } ?? "# icon: \(iconHint)"
    return """
      schema: prowl.workflow/v1
      id: \(yamlString(request.id))
      name: \(yamlString(request.name))
      description: \(description)
      \(icon)                # optional SF Symbol shown by the entry points
      """
  }

  /// Quote user text so YAML cannot treat punctuation or scalar-looking names as syntax.
  private static func yamlString(_ value: String) -> String {
    let escaped = value.unicodeScalars.map { scalar -> String in
      switch scalar.value {
      case 0x22: return "\\\""
      case 0x5C: return "\\\\"
      case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
        return String(format: "\\u%04X", scalar.value)
      default: return String(scalar)
      }
    }.joined()
    return "\"\(escaped)\""
  }

  private static func singleAgent(_ request: Request) -> String {
    """
    \(header(
      request,
      explanation: """
        # A single-agent workflow is a prompt template: Prowl sends the instructions below to the
        # agent in the pane you start from, then waits for its answer.
        """))
    \(identity(request, description: "Ask the current agent for today's date.", iconHint: "calendar"))

    # Inputs become choices on the start sheet; read them as {{ inputs.<name> }} in prompts.
    inputs:
      style:
        type: enum
        values: [long, short]
        default: long
        prompt: Date style

    roles:
      agent:
        source: current          # the pane the workflow is started from

    steps:
      - id: ask
        title: Ask for today's date
        message: agent
        prompt: |
          What is today's date? Answer with the date only, in {{ inputs.style }} form
          (long: "Friday, 11 September 2026"; short: "2026-09-11").
          Deliver the answer with the generated completion command.
        expect:
          delivery: date         # saved as deliveries/date.md; open it from Workflow History
          format: text

      - id: done
        notify: "Today's date is saved in {{ deliveries.date.path }}"

    """
  }

  private static func multiAgent(_ request: Request) -> String {
    """
    \(header(
      request,
      explanation: """
        # A multi-agent workflow coordinates several agents. This one plays rock-paper-scissors:
        # the agent in the current pane picks a move, then Prowl launches a second agent, tells it
        # the move, and asks for the one that beats it. Handoffs and cross reviews follow the same
        # shape — one role delivers a result, the next role reads it.
        """))
    \(identity(
      request,
      description: "The current agent picks a move; a second agent answers with the winning one.",
      iconHint: "hand.raised"))

    roles:
      player:
        source: current          # the pane the workflow is started from
      challenger:
        source: launch           # a new agent Prowl launches from an Agent Profile
        bind: ask                # ask: choose the profile on the start sheet | auto: reuse the remembered one
        placement: split         # split | tab
        direction: right         # right | left | up | down (split only)

    steps:
      - id: pick
        title: Player picks a move
        message: player
        prompt: |
          We are playing rock-paper-scissors. Pick one move: rock, paper, or scissors.
          Deliver your choice as the verdict of the generated completion command,
          with one line explaining why you picked it.
        expect:
          delivery: move
          verdicts: [rock, paper, scissors]   # the delivered verdict is the move

      - id: counter
        title: Challenger answers with the winning move
        launch: challenger
        prompt: |
          Another agent played {{ deliveries.move.verdict }} in rock-paper-scissors.
          Reply with the move that beats it and explain why in one line.
          Deliver your move as the verdict of the generated completion command.
        expect:
          delivery: counter
          verdicts: [rock, paper, scissors]

      - id: done
        notify: "{{ deliveries.move.verdict }} vs {{ deliveries.counter.verdict }} — the challenger wins"

    """
  }
}
