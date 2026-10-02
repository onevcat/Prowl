import ComposableArchitecture
import Foundation

struct BranchNameSuggestionContext: Sendable, Equatable {
  let repositoryName: String
  let existingBranchNames: [String]
  let terminalContexts: [TerminalHint]
  let llmAvailable: Bool

  struct TerminalHint: Sendable, Equatable {
    let worktreeBranch: String
    let title: String
    let activeContent: String?
  }
}

struct BranchNameSuggestionClient: Sendable {
  var suggest: @Sendable (BranchNameSuggestionContext) async -> String?
  var gatherContext:
    @MainActor @Sendable (
      _ repositoryName: String,
      _ repositoryRootURL: URL,
      _ existingBranchNames: [String]
    ) -> BranchNameSuggestionContext
}

// MARK: - Prompt Building

extension BranchNameSuggestionClient {
  nonisolated static func buildPrompt(from context: BranchNameSuggestionContext) -> String {
    let branches = context.existingBranchNames.prefix(10)
    let prefixedBranches = branches.filter { $0.contains("/") }
    let prefixNote: String
    if !prefixedBranches.isEmpty {
      let prefixes = Array(
        Set(
          prefixedBranches.compactMap { name -> String? in
            guard let idx = name.firstIndex(of: "/") else { return nil }
            return String(name[...idx])
          }
        ))
      prefixNote =
        "IMPORTANT: Existing branches use prefixes: \(prefixes.joined(separator: ", ")). "
        + "You MUST use one of these prefixes."
    } else {
      prefixNote = "Use a descriptive kebab-case name."
    }

    var parts: [String] = []
    parts.append(
      """
      Suggest a single git branch name for a new branch in the "\(context.repositoryName)" repository.

      Rules:
      - Output ONLY the branch name, nothing else
      - Maximum 50 characters
      - \(prefixNote)
      - Do NOT repeat an existing branch name

      Existing branches: \(branches.joined(separator: ", "))
      """)

    if !context.terminalContexts.isEmpty {
      parts.append("Current work in progress:")
      for ctx in context.terminalContexts {
        var line = "- Branch: \(ctx.worktreeBranch), terminal: \(ctx.title)"
        if let content = ctx.activeContent {
          let truncated = String(content.prefix(300))
          line += " | \(truncated)"
        }
        parts.append(line)
      }
    }

    return parts.joined(separator: "\n")
  }
}

// MARK: - Live Implementation

extension BranchNameSuggestionClient {
  static func live(llmService: any LLMService) -> Self {
    Self(
      suggest: { context in
        guard context.llmAvailable else { return nil }

        let prompt = buildPrompt(from: context)
        do {
          let raw = try await llmService.generate(prompt: prompt)
          return BranchNameSanitizer.validate(
            raw,
            existingBranches: context.existingBranchNames
          )
        } catch {
          return nil
        }
      },
      gatherContext: { repositoryName, _, existingBranchNames in
        BranchNameSuggestionContext(
          repositoryName: repositoryName,
          existingBranchNames: Array(existingBranchNames.prefix(10)),
          terminalContexts: [],
          llmAvailable: llmService.isAvailable
        )
      }
    )
  }
}

// MARK: - Dependency

extension BranchNameSuggestionClient: DependencyKey {
  static let liveValue = BranchNameSuggestionClient.live(
    llmService: FoundationModelLLMService()
  )

  static let testValue = BranchNameSuggestionClient(
    suggest: { _ in nil },
    gatherContext: { repositoryName, _, existingBranchNames in
      BranchNameSuggestionContext(
        repositoryName: repositoryName,
        existingBranchNames: existingBranchNames,
        terminalContexts: [],
        llmAvailable: false
      )
    }
  )
}

extension DependencyValues {
  var branchNameSuggestionClient: BranchNameSuggestionClient {
    get { self[BranchNameSuggestionClient.self] }
    set { self[BranchNameSuggestionClient.self] = newValue }
  }
}
