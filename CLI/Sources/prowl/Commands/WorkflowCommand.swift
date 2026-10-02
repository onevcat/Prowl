// ProwlCLI/Commands/WorkflowCommand.swift
// `prowl workflow`: workflow definition discovery, authoring, and execution.

import ArgumentParser
import Foundation
import ProwlCLIShared

struct WorkflowCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workflow",
    abstract: "Discover, validate, and run Agent Workflow definitions.",
    discussion: """
      Definitions are .pwlworkflow bundles (`prowl.workflow/v1`) found in the app bundle, ~/.prowl/workflows, \
      and <repo>/.prowl/workflows. `validate` and `schema` work with Prowl closed; every other \
      subcommand needs the running app.
      """,
    subcommands: [
      WorkflowListCommand.self,
      WorkflowReadCommand.self,
      WorkflowRunCommand.self,
      WorkflowTestActionCommand.self,
      WorkflowStatusCommand.self,
      WorkflowDeliverCommand.self,
      WorkflowCancelCommand.self,
      WorkflowValidateCommand.self,
      WorkflowSchemaCommand.self,
    ]
  )
}

struct WorkflowListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List the workflow definitions visible to a worktree, with validation status."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Argument(help: "Worktree id/name/path or a pane/tab handle. Defaults to the caller's pane.")
  var target: String?

  mutating func run() throws {
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode,
        command: .workflow(
          WorkflowInput(action: .list, target: try selector.resolve(positionalTarget: target)))
      )
    }
  }
}

struct WorkflowRunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Start a validated workflow in a source pane or worktree."
  )

  @Argument(help: "Workflow id or unique workflow name.") var workflow: String
  @Argument(
    help: "Optional source pane, tab, or worktree. Defaults to the caller pane when required.")
  var source: String?
  @OptionGroup var selector: SelectorOptions
  @Option(
    name: .long, help: "Role binding: launch=<profile name|UUID|auto>, pick=<pane handle|UUID>.")
  var role: [String] = []
  @Option(name: .long, help: "Workflow input as name=value. Repeat for multiple inputs.") var input: [String] = []
  @Option(name: .long, help: "Skip an awaited step at start. Repeat for multiple steps.") var skip: [String] = []
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode,
        command: .workflow(
          WorkflowInput(
            action: .run,
            target: try selector.resolve(positionalTarget: source),
            workflow: workflow,
            roleBindings: role,
            inputValues: input,
            skippedSteps: skip
          ))
      )
    }
  }
}

struct WorkflowStatusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show an active run, or the run awaiting delivery from this pane."
  )

  @Argument(help: "Workflow run UUID. Omit to inspect the calling pane's run.") var runID: String?
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode, command: .workflow(WorkflowInput(action: .status, runID: runID))
      )
    }
  }
}

struct WorkflowDeliverCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "deliver",
    abstract: "Deliver one workflow step's output from stdin or a UTF-8 file."
  )

  /// The body always travels with the request; the hard cap of dsl-spec §5 (`OUTPUT_TOO_LARGE`).
  static let maximumBodyBytes = WorkflowSizeLimits.payload

  @Argument(help: "'-' reads the output body from piped stdin (or use --file).") var input: String?
  @Option(name: .long, help: "Read the UTF-8 output body from this file instead of stdin.")
  var file: String?
  @Option(name: .long, help: "Declared verdict value, when this step requires one.") var verdict: String?
  @Option(name: .long, help: "Delivery token; defaults to $PROWL_WORKFLOW_TOKEN.") var token: String?
  @Option(name: .customLong("run"), help: "Run UUID of a manual delivery (with --step).") var runID: String?
  @Option(name: .long, help: "Step id of a manual delivery (with --run).") var step: String?
  @Flag(
    name: .long,
    help: "Deliver to the explicit --run/--step even when this pane belongs to another step.")
  var force = false
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    let body = try bodyValue()
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode,
        command: .workflow(
          WorkflowInput(
            action: .deliver,
            runID: runID,
            stepID: step,
            body: body,
            verdict: verdict,
            token: token ?? ProcessInfo.processInfo.environment[WorkflowSchema.tokenEnvironmentKey],
            force: force
          ))
      )
    }
  }

  func validate() throws {
    try Self.validate(input: input, file: file, runID: runID, step: step, force: force)
  }

  /// Argument rules, shared with the parser tests.
  static func validate(input: String?, file: String?, runID: String?, step: String?, force: Bool)
    throws
  {
    guard input != nil || file != nil else {
      throw ValidationError("Pass the output body through stdin ('-') or --file <path>.")
    }
    guard !(input != nil && file != nil) else {
      throw ValidationError("Pass the body through stdin ('-') or --file, not both.")
    }
    guard input == nil || input == "-" else {
      throw ValidationError("The only positional output source is '-'.")
    }
    guard (runID == nil) == (step == nil) else {
      throw ValidationError("--run and --step must be passed together.")
    }
    guard !force || runID != nil else {
      throw ValidationError("--force applies to an explicit --run/--step target.")
    }
  }

  private func bodyValue() throws -> String {
    let data: Data
    if let file {
      guard let contents = FileManager.default.contents(atPath: file) else {
        throw ExitError(code: CLIErrorCode.pathNotFound, message: "Could not read --file \(file).")
      }
      data = contents
    } else {
      guard isatty(fileno(stdin)) == 0 else {
        throw ExitError(
          code: CLIErrorCode.emptyInput,
          message: "workflow deliver - reads the output body from piped stdin.")
      }
      data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
    }
    guard data.count <= Self.maximumBodyBytes else {
      throw ExitError(
        code: CLIErrorCode.outputTooLarge,
        message: "The output body is \(data.count) bytes; the maximum is \(Self.maximumBodyBytes).")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument, message: "The output body is not valid UTF-8.")
    }
    return text
  }
}

struct WorkflowCancelCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cancel", abstract: "Cancel an active workflow run.")

  @Argument(help: "Workflow run UUID.") var runID: String
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode, command: .workflow(WorkflowInput(action: .cancel, runID: runID))
      )
    }
  }
}

struct WorkflowValidateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Parse and validate a workflow file locally; exits non-zero when it has errors."
  )

  enum Scope: String, ExpressibleByArgument, CaseIterable {
    case bundle
    case user
    case repo

    var value: WorkflowScope {
      switch self {
      case .bundle: .bundle
      case .user: .user
      case .repo: .repo
      }
    }
  }

  @Argument(help: "Path to a .pwlworkflow bundle directory.") var file: String
  @Option(name: .long, help: "Source scope (bundle, user, repo); inferred when omitted.") var scope: Scope?
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(
      command: WorkflowCommandPayload.commandName, output: options.outputMode,
      colorEnabled: options.colorEnabled
    ) {
      let payload = try WorkflowCommandExecutor.current().validate(path: file, scope: scope?.value)
      if payload.valid {
        try WorkflowCommandRunner.render(.validate(payload), options: options)
        return
      }
      let response = CommandResponse(
        ok: false,
        command: WorkflowCommandPayload.commandName,
        schemaVersion: WorkflowCommandPayload.schemaVersion,
        error: CommandError(
          code: CLIErrorCode.workflowInvalid,
          message:
            "\(payload.path) has \(payload.diagnostics.filter { $0.severity == .error }.count) error(s).",
          details: try RawJSON(encoding: payload)
        )
      )
      switch options.outputMode {
      case .json: OutputRenderer.render(response, mode: .json)
      case .text: print(OutputRenderer.workflowValidateText(payload))
      }
      throw ExitCode.failure
    }
  }
}

struct WorkflowSchemaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "schema",
    abstract: "Print the JSON Schema of a workflow bundle (for authoring agents and editors)."
  )

  @Flag(help: "Print the local script action manifest schema.") var action = false
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(
      command: WorkflowCommandPayload.commandName, output: options.outputMode,
      colorEnabled: options.colorEnabled
    ) {
      try WorkflowCommandRunner.render(
        .schema(try WorkflowCommandExecutor.current().schema(action: action)), options: options)
    }
  }
}

enum WorkflowSocketCommand {
  static func execute(options: GlobalOptions, makeEnvelope: () throws -> CommandEnvelope) throws {
    try CLIExecution.run(
      command: WorkflowCommandPayload.commandName, output: options.outputMode,
      colorEnabled: options.colorEnabled
    ) {
      try CLIRunner.execute(try makeEnvelope())
    }
  }
}

enum WorkflowCommandRunner {
  static func render(_ payload: WorkflowCommandPayload, options: GlobalOptions) throws {
    let response = CommandResponse(
      ok: true,
      command: WorkflowCommandPayload.commandName,
      schemaVersion: WorkflowCommandPayload.schemaVersion,
      data: try RawJSON(encoding: payload)
    )
    OutputRenderer.render(response, mode: options.outputMode)
  }
}


struct WorkflowTestActionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "test-action",
    abstract: "Run one action from an installed workflow bundle with the same native approval policy.")

  @Argument(help: "Workflow id or unique name.") var workflow: String
  @Argument(help: "builtin:collect-worktree-context or local:<action-id>.") var action: String
  @Argument(help: "Source worktree or pane.") var source: String?
  @Option(name: .long, help: "JSON object supplied to the action.") var inputJSON = "{}"
  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    guard let data = inputJSON.data(using: .utf8), data.count <= WorkflowSizeLimits.payload,
      let value = try? JSONDecoder().decode(WorkflowJSONValue.self, from: data), case .object(let inputs) = value
    else { throw ValidationError("--input-json must be a JSON object of at most 16 MiB.") }
    try WorkflowJSON.validate(value)
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(output: options.outputMode, command: .workflow(WorkflowInput(action: .run,
        target: try selector.resolve(positionalTarget: source), workflow: workflow,
        testAction: action, actionInputs: inputs)))
    }
  }
}

struct WorkflowReadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read", abstract: "Read the current workflow task or one of its granted resources.")
  @Argument(help: "Resource ID from the task response; omit to read the task.") var resource: String?
  @Option(name: .long, help: "Byte offset from the previous response; reads at most 256 KiB.") var offset: Int64 = 0
  @Option(name: .customLong("run"), help: "Assigned workflow run UUID.") var runID: String
  @Option(name: .long, help: "Assigned invocation number.") var invocation: Int
  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try WorkflowSocketCommand.execute(options: options) {
      CommandEnvelope(
        output: options.outputMode,
        command: .workflow(WorkflowInput(
          action: .read, invocation: invocation, contentOffset: offset, contentResource: resource, runID: runID)))
    }
  }
}
